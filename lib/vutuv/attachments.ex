defmodule Vutuv.Attachments do
  @moduledoc """
  Files on posts and messages (issue #2104): a PDF, a plain text file or a
  Markdown file, up to the installation's cap, within a budget per member — and
  in a **message between two connected members** (#2110) the photo formats
  besides, each a file whose single preview page is the picture itself.

  ## One chokepoint

  `create_pending/3` is the only way a file enters this installation, and it
  refuses in this order, cheapest first:

    1. the installation, or this member, may not upload at all;
    2. the file is over the per-file cap — answered from `File.stat!/1`,
       before a byte is read;
    3. the name's extension is not one this host offers;
    4. the **bytes** are not the kind the name claims
       (`Vutuv.Attachments.Format`);
    5. the member has no budget left;
    6. a PDF does not pass the gate (`Vutuv.Uploads.PdfGate`) — last, because
       it is the only step that shells out and reads the whole file.

  Only then is anything written to disk. A refusal leaves no file and costs no
  budget.

  ## The budget

  Two rolling windows — 24 hours and 30 days — counted from
  `Vutuv.Attachments.Upload`, a ledger row per **accepted** upload. Rolling
  rather than calendar so there is no midnight at which twice the day's budget
  fits, and a ledger rather than a sum over `attachments` so deleting a file
  gives nothing back. Admins have no budget.

  ## Off switch

  `enabled?/0` is the product flag; `uploads_for?/1` adds the audience, which
  is `:admins` until a post can actually hand a file out (#2108) and `:members`
  after — the way video was introduced. It gates a message's picker as much as
  the composer's. PDFs need poppler
  (`pdfinfo`, `pdfdetach`): without it they are not offered and the gate
  refuses them, because a check that cannot run is not a check that passed.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Attachments.Format
  alias Vutuv.Attachments.PagePipeline
  alias Vutuv.Attachments.Pages
  alias Vutuv.Attachments.Upload
  alias Vutuv.AttachmentStore
  alias Vutuv.Chat
  alias Vutuv.Images
  alias Vutuv.Images.Image
  alias Vutuv.MediaJobs
  alias Vutuv.Posts.Pending
  alias Vutuv.Repo
  alias Vutuv.Uploads.PdfGate
  alias Vutuv.Uploads.Spec

  @pending_max_age_hours 24
  @day_hours 24
  @month_hours 24 * 30

  # The version a reader is shown a preview page at, and the default of
  # `page_url/3` — the same one `Vutuv.Attachments.Pages` judges a page by.
  @preview_version "lite"

  ## Configuration

  @doc "Whether this installation offers files at all."
  def enabled?, do: Keyword.get(config(), :enabled, true)

  @doc """
  Whether this member may attach a file: an admin always, anyone else once the
  installation opens uploads (`ATTACHMENT_UPLOADERS=members`).
  """
  def uploads_for?(%User{admin?: true}), do: enabled?()
  def uploads_for?(%User{}), do: enabled?() and uploaders() == :members
  def uploads_for?(_anonymous), do: false

  def max_filesize, do: Keyword.fetch!(config(), :max_filesize)
  def max_per_post, do: Keyword.fetch!(config(), :max_per_post)
  def daily_budget, do: Keyword.fetch!(config(), :daily_budget)
  def monthly_budget, do: Keyword.fetch!(config(), :monthly_budget)

  @doc "Whether PDFs can be checked here — without poppler they are not offered."
  defdelegate pdf_supported?, to: PdfGate, as: :available?

  @doc "Drops the cached poppler probe. For tests that move the binary."
  defdelegate forget_capability, to: PdfGate

  defdelegate extension_whitelist(opts \\ []), to: Format

  defp uploaders, do: Keyword.get(config(), :uploaders, :admins)
  defp config, do: Application.fetch_env!(:vutuv, :attachments)

  ## The upload

  @doc """
  Keeps the upload at `path` under `filename` and answers `{:ok, attachment}`,
  or `{:error, reason}` — see the moduledoc for the order the refusals come
  in. Nothing is stored until every check has passed.
  """
  def create_pending(%User{} = user, path, filename) do
    if uploads_for?(user) do
      job =
        MediaJobs.start("attachment_intake",
          user_id: user.id,
          detail: Format.extension(filename)
        )

      user |> accept(path, filename) |> settle(job)
    else
      {:error, :disabled}
    end
  end

  defp accept(user, path, filename) do
    size = File.stat!(path).size

    with :ok <- check_size(size),
         {:ok, kind} <- check_format(path, filename),
         :ok <- check_budget(user, size),
         {:ok, pages} <- check_content(kind, path) do
      store(user, path, filename, kind, size, pages)
    end
  end

  defp check_size(size), do: if(size > max_filesize(), do: {:error, :too_large}, else: :ok)

  # The bytes decide what the file is; the extension only has to agree with them
  # at the level of the family, so a PNG a phone named `.jpg` is still a picture
  # and is stored as what it is, while a ZIP under either name is refused.
  defp check_format(path, filename) do
    claimed = Format.claimed_kind(filename)

    cond do
      claimed == nil ->
        {:error, :invalid_file}

      claimed == :pdf and not pdf_supported?() ->
        {:error, :pdf_unavailable}

      # Sniffed only in the branch that needs it, never above the `cond`: the
      # text answer reads the whole file, and a `.zip` picked by mistake must be
      # refused on its name without 20 MB going through a regex first.
      true ->
        agrees(Format.sniff(path), claimed)
    end
  end

  defp agrees(nil, _claimed), do: {:error, :invalid_file}

  defp agrees(sniffed, claimed),
    do: if(Format.family(sniffed) == claimed, do: {:ok, sniffed}, else: {:error, :invalid_file})

  defp check_content(:pdf, path), do: PdfGate.check(path)
  defp check_content(:text, _path), do: {:ok, nil}

  # A picture is vetted by the same decoder that will derive its preview
  # (issue #2110): `open_rotated/1` refuses what libvips cannot read, anything
  # past the pixel budget, and an SVG carrying script. Refusing here means the
  # member is told why, instead of getting an accepted file that quietly ends
  # up with no preview. `page_count` stays nil — it counts a PDF's pages, and a
  # picture has none.
  defp check_content(_picture, path) do
    case Spec.open_rotated(path) do
      {:ok, _image} -> {:ok, nil}
      {:error, _reason} -> {:error, :invalid_image}
    end
  end

  # Which of the two ran out decides what the member is told, so this asks them
  # apart rather than comparing one combined number.
  defp check_budget(user, size) do
    case budget_for(user) do
      %{unlimited?: true} -> :ok
      %{daily: %{remaining: left}} when left < size -> {:error, :daily_budget}
      %{monthly: %{remaining: left}} when left < size -> {:error, :monthly_budget}
      _room -> :ok
    end
  end

  defp store(user, path, filename, kind, size, pages) do
    token = Attachment.gen_token()
    :ok = AttachmentStore.store(token, path, Format.stored_extension(kind, filename))

    insert =
      %Attachment{user_id: user.id}
      |> Attachment.changeset(%{
        token: token,
        # Cut rather than raise 22001 on a name the member did not choose to
        # be long: a browser will happily hand over 400 characters.
        file_name: String.slice(Path.basename(filename), 0, Attachment.name_max()),
        content_type: Format.content_type(kind, filename),
        size_bytes: size,
        page_count: pages
      })
      |> Repo.insert()

    case insert do
      {:ok, attachment} ->
        record_upload!(user, size)
        # The preview pages (#2105) are rendered in the background, not here:
        # poppler and Chromium both take seconds, and the composer's socket
        # already waits for the PDF gate. The pipeline would find the row at
        # its next poll anyway — this only saves the wait.
        PagePipeline.nudge()
        {:ok, attachment}

      {:error, _changeset} = error ->
        AttachmentStore.delete(token)
        error
    end
  end

  # The intake is a media job like the photo scan and the video conversion
  # (#2103). A refusal is a **finished** job — the pipeline did its work and
  # the answer was no; only a step that could not be run is `failed`.
  defp settle({:ok, attachment} = result, job) do
    MediaJobs.finish(job, detail: "stored #{attachment.content_type}")
    result
  end

  defp settle({:error, :unreadable} = result, job) do
    MediaJobs.fail(job, :unreadable)
    result
  end

  defp settle({:error, reason} = result, job) do
    MediaJobs.finish(job, detail: "refused: #{reason}")
    result
  end

  ## The budget

  @doc """
  What is left of this member's two budgets, in bytes:

      %{unlimited?: false,
        daily: %{used:, limit:, remaining:}, monthly: %{…}}

  An admin gets `%{unlimited?: true, daily: nil, monthly: nil}` — the composer
  says so in words rather than showing a number.
  """
  def budget_for(%User{admin?: true}) do
    %{unlimited?: true, daily: nil, monthly: nil}
  end

  def budget_for(%User{} = user) do
    {day, month} = used_since(user, @day_hours, @month_hours)

    %{
      unlimited?: false,
      daily: window(day, daily_budget()),
      monthly: window(month, monthly_budget())
    }
  end

  defp window(used, limit), do: %{used: used, limit: limit, remaining: max(limit - used, 0)}

  # Both windows in one round trip: the rows the month reads are a superset of
  # the day's, so a second query would walk the same index range again.
  # Postgres sums a bigint into a numeric, which arrives as a `Decimal` and
  # cannot be subtracted from the limit — cast in SQL rather than unwrapping
  # each one here.
  defp used_since(%User{id: user_id}, day_hours, month_hours) do
    day_cutoff = hours_ago(day_hours)
    month_cutoff = hours_ago(month_hours)

    from(u in Upload,
      where: u.user_id == ^user_id and u.inserted_at > ^month_cutoff,
      select: {
        type(
          coalesce(
            fragment(
              "sum(?) FILTER (WHERE ? > ?)",
              u.size_bytes,
              u.inserted_at,
              type(^day_cutoff, :naive_datetime)
            ),
            0
          ),
          :integer
        ),
        type(coalesce(sum(u.size_bytes), 0), :integer)
      }
    )
    |> Repo.one()
  end

  defp hours_ago(hours),
    do: NaiveDateTime.add(NaiveDateTime.utc_now(), -hours * 3600, :second)

  @doc """
  Charges `size` bytes to `user`'s budget. `:hours_ago` backdates the entry,
  which is how a test puts a member at their monthly budget without waiting a
  month.
  """
  def record_upload!(%User{} = user, size, opts \\ []) do
    at =
      NaiveDateTime.utc_now(:second)
      |> NaiveDateTime.add(-Keyword.get(opts, :hours_ago, 0) * 3600, :second)

    Repo.insert!(%Upload{user_id: user.id, size_bytes: size, inserted_at: at})
  end

  ## Reading

  @doc """
  Whether this row still belongs to nobody. Both parents are nullable, so this
  is the one place that asks — every other caller goes through here rather
  than writing its own `is_nil/2` pair and getting one of them wrong.
  """
  def pending?(%Attachment{post_id: nil, message_id: nil}), do: true
  def pending?(%Attachment{}), do: false

  @doc """
  The member's own still-unattached files, oldest first — what a re-mounted
  composer re-adopts, and what `ids` narrows it to when the form named some.
  """
  def pending_for(%User{id: user_id}, ids) when is_list(ids) do
    ids = Enum.filter(ids, &(Vutuv.UUIDv7.cast_or_nil(&1) != nil))

    if ids == [] do
      []
    else
      # `unreserved/1` is what keeps a file a waiting post already holds (#2106)
      # out: re-adopting it would put the same file under two posts, and the
      # first of them to publish would take it.
      from(a in Attachment,
        where: a.user_id == ^user_id and a.id in ^ids,
        order_by: [asc: a.inserted_at]
      )
      |> unclaimed()
      |> unreserved()
      |> Repo.all()
    end
  end

  @doc """
  Whether this file has finished everything the server does to it: rendered,
  every preview page past the AI check, not refused and not held by a case.

  The pipeline half is `Vutuv.Posts.Pending.file_state/1`, which is **the one
  definition** of "done" for a file — the composer's chip, a waiting post's row
  and a message's bubble must not be able to answer it differently. What is
  added here is the freeze, which is not about the pipeline at all.
  """
  def settled?(%Attachment{} = attachment),
    do: not frozen?(attachment) and Pending.file_state(attachment) == :done

  @doc """
  Whether `viewer` may fetch this file's bytes — the **read** half of the
  connection gate (issue #2110), asked again on every request rather than
  decided once when the message was sent.

  Both halves of the nullable parent pair get a clause matching on the
  **column**, and the answer is the parent's:

    * a file under a **message** is readable while the two members are still
      connected and the viewer is one of them (`Vutuv.Chat`) — the sender at
      any stage, so their own bubble can show them what they sent, the
      recipient only once it has `settled?/1`. A connection ended after the
      message was sent closes it again for **both** sides: unfollowing is the
      only lever this app gives anybody over a conversation, and a file that
      stayed readable would leave exactly the unsolicited file from a stranger
      the whole rule exists to keep out. Nothing is deleted, so connecting
      again brings it back.
    * a file under a **post** has no address yet (#2108 gives it one), and a
      check that cannot be made is a check that failed;
    * a file with **neither** parent is the composer's own — its uploader sees
      it in the strip they are about to send it from, and nobody else.
  """
  def readable_by?(attachment, viewer)

  def readable_by?(%Attachment{message_id: id} = attachment, %User{} = viewer)
      when is_binary(id) do
    Chat.message_file_reader?(id, viewer) and
      read_reason(attachment, viewer, Pending.file_state(attachment)) == :ok
  end

  def readable_by?(%Attachment{post_id: id}, _viewer) when is_binary(id), do: false
  def readable_by?(%Attachment{frozen_at: %NaiveDateTime{}}, _viewer), do: false
  def readable_by?(%Attachment{user_id: id}, %User{id: id}), do: true
  def readable_by?(%Attachment{}, _viewer), do: false

  @doc """
  The same answer for every file in one already-authorized conversation, as
  `%{attachment_id => reason}` — what a rendered thread asks, where
  `readable_by?/2` per file would run two queries each.

  The **reason**, not a boolean, because a bubble has to say why a file is not
  there and the four answers are different sentences: `:ok`, `:working` (the
  check is still running), `:refused`, `:frozen` (a case holds it) and
  `:not_connected` (the two members are not vernetzt any more). A screen that
  says "being checked" about a settled file it may simply no longer have is
  worse than one that says nothing — which is what it said until a browser
  showed it.

  The caller has to have established the two things this does not re-ask: that
  the viewer is a participant (`Vutuv.Chat.get_conversation/2` is what hands
  them the conversation) and that the messages are ones they may see
  (`messages_page/3` filters a frozen message out). What is left is the
  connection, which is one answer for the whole thread, and the pipeline state,
  which `Vutuv.Posts.Pending.file_states/1` counts in one query for all of them.

  It shares its per-file half with `readable_by?/2`, so the thread and the
  proxy cannot answer differently.
  """
  def readable_in_conversation(files, %User{} = viewer, conversation) when is_list(files) do
    if Chat.files_allowed?(conversation) do
      states = Pending.file_states(files)

      Map.new(files, fn file ->
        {file.id, read_reason(file, viewer, Map.get(states, file.id, :working))}
      end)
    else
      Map.new(files, &{&1.id, :not_connected})
    end
  end

  # The half that needs no query once the parent's gate has answered: a held
  # file is nobody's, the member who uploaded it sees it at every stage, and
  # everybody else waits for the pipeline.
  defp read_reason(%Attachment{frozen_at: %NaiveDateTime{}}, _viewer, _state), do: :frozen
  defp read_reason(%Attachment{user_id: id}, %User{id: id}, _state), do: :ok
  defp read_reason(%Attachment{}, _viewer, :done), do: :ok
  defp read_reason(%Attachment{}, _viewer, state), do: state

  @doc """
  One file by its URL token, or `nil` — what the serving proxy resolves before
  it asks `readable_by?/2`.
  """
  def get_by_token(token) when is_binary(token),
    do: Repo.one(from(a in Attachment, where: a.token == ^token))

  def get_by_token(_token), do: nil

  @doc """
  Where this file is handed out — **the one function that owns the address**,
  so a surface never spells the proxy's path itself and the day a second parent
  kind gets its own route (#2108) there is one place to change.
  """
  def file_url(%Attachment{token: token}), do: "/system/attachments/#{token}/file"

  @doc "One served size of one of its preview pages, at the same address."
  def page_url(%Attachment{token: token}, %Image{} = page, version \\ @preview_version),
    do: "/system/attachments/#{token}/pages/#{page.position}/#{version}#{Spec.served_ext()}"

  @doc """
  The files hanging under one message, in upload order (issue #2110). The
  message's own `:attachments` preload is what the thread uses; this is for the
  paths that hold an id rather than a row.
  """
  def for_message(%{id: message_id}) when is_binary(message_id) do
    from(a in Attachment,
      where: a.message_id == ^message_id,
      order_by: [asc: a.inserted_at],
      # Every caller shows or deletes the file, and both need its pages next.
      preload: :pages
    )
    |> Repo.all()
  end

  @doc """
  Hands `ids` to a parent — `{:post, id}` or `{:message, id}` — inside the
  caller's transaction, or answers `{:error, :invalid_attachments}` and changes
  nothing.

  **One claim for both parents**, because the guard is what matters and it must
  not drift: the uploader's own rows, held by neither parent yet
  (`unclaimed/1`, the query-side twin of `pending?/1`). A count that does not
  match means one of the ids was not the member's to give, which is a refusal
  rather than a post or a message with the files quietly dropped.

  The **reservation** is where the two genuinely differ, and it is not a
  shortcut. A waiting post names its own files in `pending_post_id` (#2106) and
  clears that in the same statement it claims them, so a reserved file is
  exactly what it is entitled to take. A message never reserves anything, so a
  reserved file is somebody's waiting post's and must not be taken from it.
  """
  def claim(_parent, _uploader_id, []), do: :ok

  def claim(parent, uploader_id, ids) when is_binary(uploader_id) and is_list(ids) do
    {count, _} =
      from(a in Attachment, where: a.id in ^ids and a.user_id == ^uploader_id)
      |> unclaimed()
      |> claim_scope(parent)
      |> Repo.update_all(set: claim_set(parent))

    if count == length(ids), do: :ok, else: {:error, :invalid_attachments}
  end

  defp claim_scope(query, {:message, _id}), do: unreserved(query)
  defp claim_scope(query, {:post, _id}), do: query

  defp claim_set({:post, id}),
    do: [post_id: id, pending_post_id: nil, updated_at: NaiveDateTime.utc_now(:second)]

  defp claim_set({:message, id}),
    do: [message_id: id, updated_at: NaiveDateTime.utc_now(:second)]

  @doc """
  Narrows a query to the rows neither parent holds — the query-side twin of
  `pending?/1`, so "belongs to nobody" has one definition rather than one per
  caller.
  """
  def unclaimed(query),
    do: from(a in query, where: is_nil(a.post_id) and is_nil(a.message_id))

  @doc """
  Narrows it further to the rows no waiting post has reserved (#2106) — what a
  message's claim and a re-mounted composer both need, and what a publishing
  post deliberately does not.
  """
  def unreserved(query), do: from(a in query, where: is_nil(a.pending_post_id))

  @doc """
  Deletes every file a message carries, bytes and all — what "files stay as
  long as the conversation does" means when the conversation, or the message,
  goes.

  The rows would cascade with the message on their own; the **disk** would not,
  and a served copy nothing points at is a leak nobody would ever notice. So
  this runs before the row goes, from `Vutuv.Chat`.
  """
  def purge_for_message(message) do
    for attachment <- for_message(message), do: purge(attachment)
    :ok
  end

  @doc """
  The same for every message of one conversation, in **one** query rather than
  one per message: deleting a long thread would otherwise ask about hundreds of
  messages that carry nothing.
  """
  def purge_for_conversation(conversation_id) when is_binary(conversation_id) do
    from(a in Attachment,
      join: m in Vutuv.Chat.Message,
      on: m.id == a.message_id,
      where: m.conversation_id == ^conversation_id,
      preload: :pages
    )
    |> Repo.all()
    |> Enum.each(&purge/1)
  end

  @doc "The files a waiting post holds, in upload order (issue #2106)."
  def for_pending_post(%{id: pending_post_id}) do
    from(a in Attachment,
      where: a.pending_post_id == ^pending_post_id,
      order_by: [asc: a.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Records that the AI check refused one of this file's preview pages (#2106).
  The **file** is untouched — what happens to a file whose contents are refused
  is the upload gate's question — but the post waiting on it stops waiting,
  because the page the verdict deleted is never coming back. Idempotent: the
  first verdict is the one that counts.
  """
  def refuse(%Attachment{} = attachment) do
    now = DateTime.utc_now(:second)

    {count, _} =
      from(a in Attachment, where: a.id == ^attachment.id and is_nil(a.refused_at))
      |> Repo.update_all(set: [refused_at: now, updated_at: NaiveDateTime.utc_now(:second)])

    if count == 1 do
      refused = %{attachment | refused_at: now}
      announce(refused)
      refused
    else
      attachment
    end
  end

  @doc """
  Tells every surface that shows this file's state that it moved: the
  uploader's own (the composer chip, a waiting post's card, `/system/uploads` —
  issue #2106) and, when a message carries it, that conversation, whose
  recipient is watching a bubble for exactly this.

  One function rather than a second `Phoenix.PubSub` call remembered at each of
  the three sites, which is how a file settles for its author and stays
  "being checked" for the person it was sent to.
  """
  def announce(%Attachment{} = attachment) do
    Pending.broadcast_attachment(attachment)
    Pending.media_changed(:attachment, attachment.id)
    Chat.attachment_changed(attachment)
    :ok
  end

  ## The copyright freeze (issue #2109)

  @doc "Whether a case is holding this file offline right now."
  def frozen?(%Attachment{frozen_at: %NaiveDateTime{}}), do: true
  def frozen?(%Attachment{}), do: false

  @doc """
  Whether a moderation case may act on this file at all — the twin of
  `Vutuv.Images.takedown_ready?/1`, and what `Vutuv.Moderation` asks before it
  lets a report name one.

  Published (a post or a message holds it) and not already held. A file the
  composer still has belongs to nobody outside, and a file another case has
  already taken offline is not there to be reported again — answering otherwise
  would tell a stranger it exists, which is the whole rule
  `Vutuv.Moderation.ContentUrl` is built on.
  """
  def takedown_ready?(%Attachment{} = attachment),
    do: not pending?(attachment) and not frozen?(attachment)

  @doc """
  Takes this file offline without deleting a byte of it: the row is stamped
  `frozen_at`, every preview page freezes with it (`Vutuv.Images.freeze/1`, so
  each page's own row carries the stamp every display gate already reads), and
  the file's two copies move into the hold.

  **Order matters**, as it does for a picture. The stamp goes first: it is the
  record that this file is meant to be held, so a slot that dies mid-move leaves
  a file that is already invisible and a job `reconcile_holds/0` finishes. The
  other order would leave files in a hold that nothing knows to bring back.
  """
  def freeze(%Attachment{} = attachment) do
    now = NaiveDateTime.utc_now(:second)

    # `is_nil(frozen_at)` so a second pass — `reconcile_holds/0` finishing an
    # interrupted move — re-asserts the freeze without moving the moment it
    # happened, which is what the case and the statement of reasons quote.
    Repo.update_all(
      from(a in Attachment, where: a.id == ^attachment.id and is_nil(a.frozen_at)),
      set: [frozen_at: now, updated_at: now]
    )

    # Only the pages that are not stamped yet. A page that is carries its own
    # hold on the `images` table, which `Vutuv.Images.reconcile_holds/0`
    # re-asserts one line before this function runs on the sweeper — doing it
    # here as well would be that whole pass again, per page, every 15 minutes.
    for page <- Pages.list(attachment), is_nil(page.frozen_at), do: Images.freeze(page)
    AttachmentStore.hold(attachment.id, attachment.token)
    :ok
  end

  @doc """
  Puts a held file back exactly where it was — every page first, then the file
  itself — and removes the hold.

  Idempotent, and safe to run again after an interruption: the hold is removed
  only once the files are back, so a half-finished restore is still a hold for
  `reconcile_holds/0` to find.
  """
  def unfreeze(%Attachment{} = attachment) do
    Repo.update_all(from(a in Attachment, where: a.id == ^attachment.id),
      set: [frozen_at: nil, updated_at: NaiveDateTime.utc_now(:second)]
    )

    for page <- Pages.list(attachment), do: Images.unfreeze(page)
    AttachmentStore.release(attachment.id, attachment.token)
    AttachmentStore.purge_hold(attachment.id)
    :ok
  end

  @doc """
  Deletes this file for good — every preview page, both copies of the file and
  the held ones — and forgets the row. What an upheld copyright case does, and
  what the owner's own "remove it" does.

  **The post is untouched.** The claim is about these bytes, not about the text
  that carried them.
  """
  def purge(%Attachment{} = attachment) do
    for page <- Pages.list(attachment), do: Images.purge(page)
    Repo.delete_all(from(a in Attachment, where: a.id == ^attachment.id))
    AttachmentStore.delete(attachment.token)
    AttachmentStore.purge_hold(attachment.id)
    :ok
  end

  @doc """
  Where this file's bytes are **right now**, wherever that is: the takedown hold
  while a case holds it, otherwise the served copy — the twin of
  `Vutuv.Images.bytes_path/2`, and the one answer both case pages need. A freeze
  takes the file out of every tree this app serves from, so an admin ruling on a
  copyright claim can read it only through this.
  """
  def bytes_path(%Attachment{} = attachment),
    do: held_file_path(attachment) || AttachmentStore.served_path(attachment.token)

  @doc "Only the held copy, or `nil` — the half `bytes_path/1` asks first."
  def held_file_path(%Attachment{id: id}), do: AttachmentStore.held_path(id)

  @doc """
  Finishes every move a dying slot left half-done, in both directions — the
  standing job behind `freeze/1` and `unfreeze/1`, run beside
  `Vutuv.Images.reconcile_holds/0` by `Vutuv.Moderation.Sweeper`.

  The row's `frozen_at` is the intent and the disk is the state, so this reads
  the intent and re-asserts it: a frozen file has whatever is left of it moved
  into the hold, a hold whose row is no longer frozen is released, and a hold
  whose row is gone (an upheld case interrupted between the two) is deleted.
  The same three passes the image twin runs, and for the same reason — a slot
  that died between the `frozen_at: nil` write and the move would otherwise
  leave a file's bytes in a hold nothing knows to bring back.

  It is a separate function rather than a case in the image one because the two
  read different tables: `Vutuv.Images.reconcile_holds/0` only ever sees `images`
  rows, and this hold deliberately lives where its leftover sweep cannot reach.
  """
  def reconcile_holds do
    frozen = Repo.all(from(a in Attachment, where: not is_nil(a.frozen_at)))
    for attachment <- frozen, do: freeze(attachment)

    frozen_ids = MapSet.new(frozen, & &1.id)
    leftover = Enum.reject(AttachmentStore.held_ids(), &MapSet.member?(frozen_ids, &1))

    release_leftover_holds(leftover)
  end

  defp release_leftover_holds([]), do: :ok

  defp release_leftover_holds(ids) do
    rows = Repo.all(from(a in Attachment, where: a.id in ^ids))
    for attachment <- rows, do: unfreeze(attachment)

    known = MapSet.new(rows, & &1.id)
    for id <- ids, not MapSet.member?(known, id), do: AttachmentStore.purge_hold(id)

    :ok
  end

  ## Deleting and sweeping

  @doc """
  Removes the member's own still-unattached file, bytes and all. A no-op for
  one that already belongs to a post or a message — those go with their
  parent. The budget keeps the bytes: they were accepted.

  Through `purge/1` rather than deleting the row and the directory itself: this
  used to `rm_rf` the token's tree, which took the preview pages' **files** and
  left their `images` rows behind pointing at nothing (issue #2105 renders them
  the moment a file lands, so a file the composer abandons has them).
  """
  def delete_pending(%Attachment{} = attachment) do
    if pending?(attachment), do: purge(attachment)
    :ok
  end

  @doc """
  Removes files older than `max_age_hours` that no post and no message ever
  claimed. Returns how many went.

  Prunes by age rather than picking work oldest-first, so the sweeper-clock
  trap does not apply: a deleted row cannot come round again.
  """
  def sweep_pending(max_age_hours \\ @pending_max_age_hours) do
    cutoff = hours_ago(max_age_hours)

    rows =
      from(a in Attachment,
        as: :attachment,
        where: is_nil(a.post_id) and is_nil(a.message_id),
        where: a.inserted_at <= ^cutoff,
        # Not a file a post is still waiting on (#2106). A render that took a
        # day, or an author who has not yet answered a refusal, must not have
        # the file deleted out from under the text.
        where:
          not exists(
            from(p in Vutuv.Posts.PendingPost,
              where:
                p.id == parent_as(:attachment).pending_post_id and
                  p.status in ["waiting", "publishing"]
            )
          )
      )
      |> Repo.all()

    Enum.each(rows, &delete_pending/1)
    length(rows)
  end
end
