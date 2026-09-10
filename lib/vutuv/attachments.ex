defmodule Vutuv.Attachments do
  @moduledoc """
  Files on posts and messages (issue #2104): a PDF, a plain text file or a
  Markdown file, up to the installation's cap, within a budget per member.

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
  is `:admins` until a post can actually carry a file (#2106, #2108) and
  `:members` after — the way video was introduced. PDFs need poppler
  (`pdfinfo`, `pdfdetach`): without it they are not offered and the gate
  refuses them, because a check that cannot run is not a check that passed.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Attachments.Format
  alias Vutuv.Attachments.PagePipeline
  alias Vutuv.Attachments.Upload
  alias Vutuv.AttachmentStore
  alias Vutuv.MediaJobs
  alias Vutuv.Posts.Pending
  alias Vutuv.Repo
  alias Vutuv.Uploads.PdfGate

  @pending_max_age_hours 24
  @day_hours 24
  @month_hours 24 * 30

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

  defdelegate extension_whitelist, to: Format

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

  defp check_format(path, filename) do
    claimed = Format.claimed_kind(filename)

    cond do
      claimed == nil -> {:error, :invalid_file}
      claimed == :pdf and not pdf_supported?() -> {:error, :pdf_unavailable}
      Format.sniff(path) != claimed -> {:error, :invalid_file}
      true -> {:ok, claimed}
    end
  end

  defp check_content(:pdf, path), do: PdfGate.check(path)
  defp check_content(:text, _path), do: {:ok, nil}

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
      from(a in Attachment,
        where: a.user_id == ^user_id and a.id in ^ids,
        where: is_nil(a.post_id) and is_nil(a.message_id),
        # A file a waiting post already holds (#2106) is not the composer's to
        # pick up again: re-adopting it would put the same file under two
        # posts, and the first of them to publish would take it.
        where: is_nil(a.pending_post_id),
        order_by: [asc: a.inserted_at]
      )
      |> Repo.all()
    end
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
      Pending.broadcast_attachment(refused)
      refused
    else
      attachment
    end
  end

  ## Deleting and sweeping

  @doc """
  Removes the member's own still-unattached file, bytes and all. A no-op for
  one that already belongs to a post or a message — those go with their
  parent. The budget keeps the bytes: they were accepted.
  """
  def delete_pending(%Attachment{} = attachment) do
    if pending?(attachment) do
      Repo.delete(attachment, allow_stale: true)
      AttachmentStore.delete(attachment.token)
    end

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
