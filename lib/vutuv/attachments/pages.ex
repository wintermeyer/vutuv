defmodule Vutuv.Attachments.Pages do
  @moduledoc """
  The preview pages under a post's file (issue #2105): the first pages of a
  PDF, or a text/Markdown file drawn as one page, so a reader can tell what a
  file is without downloading it.

  Each page is a row on the shared `images` table of kind `attachment_page`,
  parented by `attachment_id` and ordered by `position` — the shape #2083 gave
  the press kit, and the second kind **born** on that table rather than
  mirrored into it. What that buys, and what it does not, is worth stating
  plainly, because the issue this was built from assumed all six:

    * **The AI image scan** reaches it — but only because this change adds
      `attachment_page` to `Vutuv.Moderation.ImageScan.kinds/0` and a clause
      each to `source/1`, `apply_approved/1`, `apply_rejected/1` and
      `stranded_pending/0` in `Vutuv.Moderation.ImageSubjects`. Nothing there
      is generic.
    * **The pixelated wait** reaches it because `store_page/3` writes the
      stand-in; the markup that shows it is #2108's.
    * **The lite version** reaches it because the `:attachment_page` entry in
      `Vutuv.Uploads.Spec` declares one.
    * **The regenerator** reaches it because `Vutuv.Uploads.Regenerator` names
      it in four places.
    * **The lightbox** is the one thing that really is generic: the JS reads
      data attributes off whatever markup carries them.
    * **The copyright freeze does not reach it, on purpose.** A kind in
      `Vutuv.Images`' `@takedown` map is reportable by anyone who can name a
      row id, with no visibility check at all
      (`Vutuv.Moderation.reportable_by?/2`'s catch-all `%Image{}` clause) — and
      a preview page can belong to a file no post has claimed yet. Reporting a
      file is #2109, and it wires the strategy and the visibility clause
      together. Until then nothing offers a report button for a page, and
      `Vutuv.Images.takedown_ready?/1` answers false, which is the honest state.

  ## Surviving a deploy

  Rendering three PDF pages plus their AVIF derivations takes seconds and a
  Chromium capture takes longer, so a blue/green deploy stops the slot in the
  middle of it and nothing logs a thing. The recovery is the shape
  `Vutuv.Videos` already uses and `Vutuv.Newsletters.BroadcastResumer`
  established:

    * the **row** carries the state (`stage`), never a process;
    * each finished page gets its **own row** (`images`), so a resumed render
      skips what is already there rather than deriving it twice;
    * the due list is a **query** (`due/1`), and a claim is a compare-and-set
      on `worked_at`, so the two slots of a deploy overlap cannot render the
      same file;
    * the staleness window is longer than one file takes, which is what makes
      the resume safe while the old slot is still working.

  ## The clock advances on every outcome

  `stage` reaches `ready` or `failed` — both terminal, both out of `due/1` —
  whatever happened, **including the outcomes where nothing could be done at
  all**: previews switched off, or a host with no `pdftoppm` and no Chromium.
  A file that could not be worked on and stayed due would hold the front of
  every oldest-first batch for ever, which is the deadlock `CLAUDE.md` records
  from `Vutuv.Fediverse.refresh_counts/1`. A strike (`render_attempts`) is
  taken only when the renderer itself ran and failed, so a transient failure is
  retried and a permanent impossibility is not counted against anybody.
  """

  import Ecto.Query, warn: false

  alias Vutuv.Attachments.Attachment
  alias Vutuv.Attachments.PageRender
  alias Vutuv.AttachmentStore
  alias Vutuv.Images.Image
  alias Vutuv.MediaJobs
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Moderation.Pixelation
  alias Vutuv.Posts.Pending
  alias Vutuv.Repo
  alias Vutuv.Uploads
  alias Vutuv.UUIDv7

  require Logger

  @kind "attachment_page"

  # The ceiling issue #2105 sets: "start with three, at most five". Three pages
  # tell a reader what a document is; five is where a preview strip stops being
  # a preview and starts being the document.
  @max_pages 5
  @default_pages 3

  # Longer than one file takes, which is what makes a claim safe across a
  # blue/green overlap: while the old slot is still rendering, its heartbeat is
  # fresh and the new slot leaves the file alone. Three minutes is the video
  # pipeline's number, and a page render is far quicker than a transcode.
  @stale_after_seconds 180

  # How often the renderer may fail before the file gives up its previews. A
  # damaged PDF fails identically every time and three poppler runs cost
  # nothing; a Chromium that was merely busy gets its retries.
  @max_attempts 3

  # The version a page's bytes are judged and shown at — the largest derived
  # size, since there is no private original behind a page.
  @preview_version "large"

  @doc "This kind's name in `Vutuv.Images.kinds/0`."
  def kind, do: @kind

  @doc "The version a page is judged and shown at — what `Vutuv.Images` asks for."
  def preview_version, do: @preview_version

  @doc """
  How many of a file's first pages this installation renders
  (`ATTACHMENT_PREVIEW_PAGES`). `0` turns previews off; anything above five is
  five.
  """
  def preview_pages do
    config()
    |> Keyword.get(:preview_pages, @default_pages)
    |> min(@max_pages)
    |> max(0)
  end

  @doc "The hard ceiling `preview_pages/0` clamps to."
  def max_pages, do: @max_pages

  @doc "How long a claim stands before another slot may take the file over."
  def stale_after_seconds, do: @stale_after_seconds

  @doc "How often the renderer may fail before the file gives up its previews."
  def max_attempts, do: @max_attempts

  defp config, do: Application.fetch_env!(:vutuv, :attachments)

  ## Reading

  @doc """
  How many pages this file's render is aiming for — what the author's waiting
  card counts against to say "rendering page 2 of 3" (issue #2106).
  """
  def wanted_count(%Attachment{} = attachment),
    do: length(wanted_positions(attachment))

  @doc "This file's preview pages, first page first."
  def list(%Attachment{id: id}), do: Repo.all(page_query(id))

  # Which pages this file already has, and nothing else about them: the resume
  # only needs the numbers, and a page row carries thirty columns.
  defp rendered_positions(%Attachment{id: id}),
    do: Repo.all(from(i in page_query(id), select: i.position))

  defp page_query(attachment_id) do
    from(i in Image,
      where: i.kind == ^@kind and i.attachment_id == ^attachment_id,
      order_by: [asc: i.position]
    )
  end

  @doc """
  Where one page's bytes are, or `nil`. **The one function that owns a page's
  path**: a page is stored under its *file's* token, so every caller that built
  the path itself would have to remember that.
  """
  def bytes_path(page, version \\ @preview_version)

  def bytes_path(%Image{kind: @kind} = page, version) do
    with token when is_binary(token) <- token_of(page),
         do: AttachmentStore.page_version_path(token, page.position, version)
  end

  def bytes_path(%Image{}, _version), do: nil

  # Takes the preload when a caller remembered one and looks it up when nobody
  # did: half the callers hand over a bare row straight from a query, and an
  # answer that depends on a preload is not an answer.
  defp token_of(%Image{attachment: %Attachment{token: token}}), do: token

  defp token_of(%Image{attachment_id: id}) when is_binary(id),
    do: Repo.one(from(a in Attachment, where: a.id == ^id, select: a.token))

  defp token_of(%Image{}), do: nil

  ## The copyright freeze (issue #2109)

  @doc """
  Moves every stored size of one page into that page's own takedown hold — the
  `:attachment_page` half of `Vutuv.Images`' `@takedown` registry, and the shape
  a press picture already uses: the row's id names the hold, the store owns the
  name of the tree the files come out of.

  A page freezes **with its file**, never on its own: `Vutuv.Attachments.freeze/1`
  is the only caller, because a preview page is our derivation of a member's
  file and has no standing of its own to be taken offline for.
  """
  def hold_files(%Image{kind: @kind} = page), do: page_files(page, &Uploads.hold/2)

  @doc "The other direction, for a rejected case: the page back where it was."
  def release_files(%Image{kind: @kind} = page), do: page_files(page, &Uploads.release/2)

  defp page_files(%Image{} = page, move) do
    case token_of(page) do
      nil -> :ok
      token -> move.(page.id, AttachmentStore.page_storage_dir(token, page.position))
    end

    :ok
  end

  ## The scan's verdicts (`Vutuv.Moderation.ImageSubjects`)

  @doc """
  Lets a cleared page out of the AI gate. Guarded on the row still waiting, so
  a verdict that lost a race against a delete flips nothing and answers
  `:stale`.
  """
  def release(page_id) when is_binary(page_id) do
    from(i in Image, where: i.id == ^page_id and i.kind == ^@kind and i.moderation == "pending")
    |> Repo.update_all(set: [moderation: "approved", updated_at: NaiveDateTime.utc_now(:second)])
    |> case do
      {1, _} -> :ok
      _none -> :stale
    end
  end

  @doc """
  Deletes one page for good — the row first, then every derived size and the
  stand-in. That order is what an interruption can survive: it leaves files
  nothing points at rather than a row naming files that are gone.

  The **file itself is untouched**. The model judged the picture we derived
  from it, and what happens to a file whose contents are refused is the upload
  gate's question, not a preview's.
  """
  def discard(%Image{kind: @kind} = page) do
    token = token_of(page)
    Repo.delete_all(from(i in Image, where: i.id == ^page.id))
    if token, do: AttachmentStore.delete_page(token, page.position)
    :ok
  end

  @doc """
  A page cleared the AI check: the file may now be everything a post was
  waiting for (issue #2106), so the author's surfaces are told and the waiting
  post is published if this was the last thing.
  """
  def page_settled(%Image{kind: @kind} = page) do
    case attachment_of(page) do
      nil ->
        :ok

      attachment ->
        Pending.broadcast_attachment(attachment)
        Pending.media_changed(:attachment, attachment.id)
        :ok
    end
  end

  @doc """
  A page was refused by the AI check. The **file** is not deleted — that is the
  upload gate's question — but a post waiting on it stops waiting and its
  author is offered the two ways out (issue #2106).
  """
  def page_refused(%Image{kind: @kind} = page) do
    case attachment_of(page) do
      nil ->
        :ok

      attachment ->
        Vutuv.Attachments.refuse(attachment)
        :ok
    end
  end

  @doc "Drops the pixelated stand-in a verdict has ended the wait for."
  def drop_pixelated(%Image{kind: @kind} = page) do
    case token_of(page) do
      nil -> :ok
      token -> token |> AttachmentStore.page_dir(page.position) |> Pixelation.clear()
    end
  end

  @doc """
  One page row of this kind by id, or `nil` — never a row of another kind, so a
  scan can neither read nor write over a row of another one that happens to
  share the id.

  The file comes with it, because every caller (`source/1`, `apply_approved/1`,
  `apply_rejected/1` in `Vutuv.Moderation.ImageSubjects`) needs its token next
  and `token_of/1` would otherwise pay a second query for it.
  """
  def get_page(page_id) when is_binary(page_id) do
    Repo.one(
      from(i in Image,
        where: i.id == ^page_id and i.kind == ^@kind,
        preload: :attachment
      )
    )
  end

  ## The pipeline

  @doc """
  Files whose pages are still to be rendered, oldest first — the due list, as a
  query rather than as state in a process that a deploy takes with it.
  """
  def due(limit) when is_integer(limit) and limit > 0 do
    stale = DateTime.add(DateTime.utc_now(:second), -@stale_after_seconds, :second)

    Repo.all(
      from(a in Attachment,
        # The two stages a file still has render work in — `ready` and `failed`
        # are terminal, and leaving this set is what takes a row out of the due
        # list for good. Spelled as **literals**, matching
        # `attachments_render_due_index`'s own predicate word for word: an
        # `in ^list` binds them as a parameter, and Postgres can only
        # prove a parameterised list implies a partial index's predicate while
        # it is re-planning — the poller runs this statement for ever, so it
        # ends up on a generic plan and the index the migration built for it
        # would go unused.
        where: fragment("? IN ('stored', 'rendering')", a.stage),
        where: is_nil(a.worked_at) or a.worked_at < ^stale,
        order_by: [asc: a.inserted_at],
        limit: ^limit
      )
    )
  end

  @doc """
  The same, claimed: a compare-and-set on `worked_at`, so two slots of a deploy
  overlap can never render the same file. Reads twice the batch, because a row
  another slot took between the query and the update is skipped rather than
  retried.
  """
  def claim_due(limit) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now(:second)

    (limit * 2)
    |> due()
    |> Enum.reduce_while([], &claim_into(&1, &2, limit, now))
    |> Enum.reverse()
  end

  defp claim_into(_attachment, claimed, limit, _now) when length(claimed) >= limit,
    do: {:halt, claimed}

  defp claim_into(attachment, claimed, _limit, now) do
    case claim(attachment, now) do
      {:ok, claimed_row} -> {:cont, [claimed_row | claimed]}
      :taken -> {:cont, claimed}
    end
  end

  defp claim(%Attachment{worked_at: nil} = attachment, now) do
    from(a in Attachment, where: a.id == ^attachment.id and is_nil(a.worked_at))
    |> Repo.update_all(set: [stage: "rendering", worked_at: now])
    |> claimed(attachment, now)
  end

  defp claim(%Attachment{worked_at: seen} = attachment, now) do
    from(a in Attachment, where: a.id == ^attachment.id and a.worked_at == ^seen)
    |> Repo.update_all(set: [stage: "rendering", worked_at: now])
    |> claimed(attachment, now)
  end

  defp claimed({1, _}, attachment, now),
    do: {:ok, %{attachment | stage: "rendering", worked_at: now}}

  defp claimed(_none, _attachment, _now), do: :taken

  @doc "One pass: render every file that is due. Answers how many it worked on."
  def sweep(limit \\ 2) do
    claimed = claim_due(limit)
    Enum.each(claimed, &render/1)
    length(claimed)
  end

  @doc """
  Renders whatever of this file's pages is still missing and settles the row.
  Answers the file as it now stands.

  Safe to run again after an interruption, and that is the whole point: the
  pages that already have a row are skipped, so a slot killed after page two of
  five costs two renders, not five.
  """
  def render(%Attachment{} = attachment) do
    attachment = start_render(attachment)
    wanted = wanted_positions(attachment)

    job =
      MediaJobs.start("attachment_pages",
        user_id: attachment.user_id,
        post_id: attachment.post_id,
        subject_type: "attachment",
        subject_id: attachment.id,
        detail: attachment.content_type
      )

    cond do
      wanted == [] ->
        settle(attachment, job, "no pages wanted")

      is_nil(PageRender.renderer(attachment)) ->
        # Not a strike and not a failure: the pipeline asked, and this
        # installation has nothing that renders this format. Retrying changes
        # nothing, so the file leaves the queue rather than holding its front.
        settle(attachment, job, "no renderer for #{attachment.content_type}")

      true ->
        render_pages(attachment, wanted, job)
    end
  end

  # Which pages this file gets, as positions counted from zero.
  #
  # A PDF has its own pagination, and `pdfinfo` already counted it at upload.
  # A text or Markdown file has none: what is rendered is the document, and
  # what a page-sized viewport shows of it is one page — so slicing a long
  # README into three would produce two pictures of nothing in particular.
  defp wanted_positions(%Attachment{content_type: "application/pdf"} = attachment) do
    positions(min(preview_pages(), attachment.page_count || 1))
  end

  defp wanted_positions(%Attachment{}), do: positions(min(preview_pages(), 1))

  defp positions(count) when count > 0, do: Enum.to_list(0..(count - 1))
  defp positions(_none), do: []

  defp render_pages(attachment, wanted, job) do
    rendered = MapSet.new(rendered_positions(attachment))
    todo = Enum.reject(wanted, &MapSet.member?(rendered, &1))

    todo
    |> Enum.reduce_while(:ok, fn position, :ok ->
      case render_page(attachment, position) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> settle(attachment, job, page_count_detail(length(wanted)))
      {:error, reason} -> strike(attachment, job, reason)
    end
  end

  # The operator reads this in `/admin/media`'s Ergebnis column, so it says
  # "1 page" rather than "1 pages". Not a gettext string: every other `detail`
  # this table stores is untranslated English ("stored application/pdf",
  # "refused: too_large"), and one translated cell among them would be the odd
  # one out — and `ngettext/3` would bind `%{count}` to a raw integer anyway.
  defp page_count_detail(1), do: "1 page"
  defp page_count_detail(count), do: "#{count} pages"

  defp render_page(%Attachment{} = attachment, position) do
    dest =
      Path.join(
        System.tmp_dir!(),
        "vutuv-page-#{attachment.token}-#{position}-#{System.unique_integer([:positive])}.png"
      )

    try do
      with :ok <- PageRender.render(attachment, position, dest),
           {:ok, meta} <- AttachmentStore.store_page(attachment.token, position, dest) do
        record_page(attachment, position, meta)
      end
    after
      File.rm(dest)
    end
  end

  # `insert_all` rather than a changeset: nothing here comes from a form, and
  # the partial unique index is the conflict target that makes a resumed — or
  # doubly claimed — render idempotent. `on_conflict: :nothing` means the slot
  # that lost writes no second row and queues no second scan.
  defp record_page(%Attachment{} = attachment, position, meta) do
    now = NaiveDateTime.utc_now(:second)

    entry = %{
      id: UUIDv7.generate(),
      kind: @kind,
      attachment_id: attachment.id,
      user_id: attachment.user_id,
      token: Uploads.gen_token(),
      position: position,
      moderation: ImageScans.initial_state(),
      width: meta.width,
      height: meta.height,
      content_type: meta.content_type,
      size_bytes: meta.size_bytes,
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(Image, [entry],
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment, "(attachment_id, position) WHERE kind = 'attachment_page'"},
           returning: [:id]
         ) do
      {1, [%Image{id: id}]} ->
        ImageScans.enqueue(@kind, id, attachment.user_id)
        :ok

      _lost_the_race ->
        :ok
    end
  end

  ## Settling

  # The claim, unconditional: `render/1` is reached both from the sweeper
  # (which has already claimed) and directly, and a second stamp costs one
  # statement and removes a branch.
  defp start_render(%Attachment{} = attachment) do
    now = DateTime.utc_now(:second)

    Repo.update_all(from(a in Attachment, where: a.id == ^attachment.id),
      set: [stage: "rendering", worked_at: now]
    )

    %{attachment | stage: "rendering", worked_at: now}
  end

  # Done, however many pages that turned out to be. A refusal-shaped outcome
  # ("no renderer") is a **finished** job rather than a failed one, the
  # convention #2103 set: the pipeline did its work and the answer was none.
  defp settle(%Attachment{} = attachment, job, detail) do
    MediaJobs.finish(job, detail: detail)

    Repo.update_all(from(a in Attachment, where: a.id == ^attachment.id),
      set: [stage: "ready", worked_at: nil]
    )

    finished(%{attachment | stage: "ready", worked_at: nil})
  end

  # A terminal stage is the moment a post waiting on this file may be able to
  # go out (issue #2106) — every page it will ever get now has a row, and the
  # only thing left is the verdicts on them. Told rather than polled, so the
  # post appears the second it can.
  defp finished(%Attachment{} = attachment) do
    Pending.broadcast_attachment(attachment)
    Pending.media_changed(:attachment, attachment.id)
    attachment
  end

  defp strike(%Attachment{} = attachment, job, reason) do
    MediaJobs.fail(job, reason)
    attempts = (attachment.render_attempts || 0) + 1

    if attempts >= @max_attempts do
      Logger.warning(
        "attachment pages gave up attachment=#{attachment.id} reason=#{inspect(reason)}"
      )

      finished(write_strike(attachment, attempts, stage: "failed", worked_at: nil))
    else
      # The claim stamp is deliberately left where `start_render/1` put it. It
      # is the *scheduler's* clock, not a claim that the work happened, so the
      # retry is due one staleness window from now instead of on the very next
      # pass — which is what keeps a file that cannot be rendered from spending
      # the whole batch on itself.
      write_strike(attachment, attempts, [])
    end
  end

  defp write_strike(%Attachment{} = attachment, attempts, extra) do
    sets = Keyword.put(extra, :render_attempts, attempts)

    Repo.update_all(from(a in Attachment, where: a.id == ^attachment.id), set: sets)

    struct!(attachment, sets)
  end

  ## The regenerator's hook

  @doc """
  Re-renders one stored page and re-derives its sizes — what
  `Vutuv.Uploads.Regenerator` runs so a resolution or quality change in
  `Vutuv.Uploads.Spec` reaches preview pages too.

  There is no private original behind a page (the *file* is the original, and
  it is kept verbatim), so this really does run poppler or Chromium again. A
  page whose file is gone is left exactly as it is: `:skipped`.
  """
  def regenerate(%Image{kind: @kind} = page, _opts \\ []) do
    case attachment_of(page) do
      nil -> {:skipped, :missing_original}
      attachment -> rerender(attachment, page.position, page.token)
    end
  end

  defp rerender(%Attachment{} = attachment, position, name) do
    dest = Path.join(System.tmp_dir!(), "vutuv-regen-#{name}-#{position}.png")

    try do
      with :ok <- PageRender.render(attachment, position, dest),
           {:ok, _meta} <- AttachmentStore.store_page(attachment.token, position, dest),
           do: :ok
    after
      File.rm(dest)
    end
  end

  defp attachment_of(%Image{attachment: %Attachment{} = attachment}), do: attachment
  defp attachment_of(%Image{attachment_id: id}) when is_binary(id), do: Repo.get(Attachment, id)
  defp attachment_of(%Image{}), do: nil
end
