defmodule Vutuv.Fediverse.Media do
  @moduledoc """
  Fetching the pictures of the accounts a member follows (issue #1163): a
  cached post's image attachments and one avatar per cached account.

  Every fetch goes out to a server we do not control, on a URL that server
  chose, so it wears the same fence every other outbound request here does
  (`Vutuv.Fediverse.fetch_remote_actor/2`, `Vutuv.Fediverse.RemoteFollow`):
  https only, the host vetted against `Vutuv.Ssrf`, short timeouts, no
  redirects, and a hard byte ceiling that halts the stream rather than
  buffering. A picture is the one thing here whose *size* is the attack, so
  the ceiling is the load-bearing part and it is per file.

  **Off the request path.** The inbox must answer 202 quickly and must never
  wait on a third party's image server, so a delivery only records what it
  wants and the download happens in a task afterwards. That task is gated on
  `:fediverse_media_fetch` (off in tests, where it would run outside the SQL
  sandbox); tests call `fetch_now/1` directly.

  **Nothing is shown before the gate.** A stored file starts `pending` and the
  display chokepoint (`Vutuv.Fediverse.RemoteImage.released?/1`) refuses it
  until `Vutuv.Moderation.ImageScans` clears it. We publish nothing an unknown
  server sends us sight unseen — which is exactly why the pictures are fetched
  at all rather than hot-linked: a hot-linked image cannot be moderated, and it
  would tell that server every reader's IP address.
  """

  import Ecto.Query, only: [from: 2]

  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.RemoteMedia
  alias Vutuv.Repo
  alias Vutuv.SocialFeed.Http

  # Per file. Generous enough for a real photo off a phone, small enough that a
  # hostile server cannot make one delivery cost us a hundred megabytes.
  @max_bytes 8_000_000

  # What we will even try to decode. A video or an audio file is a "View the
  # original" link, never a download: we would be storing a media library.
  @image_types ~w(image/jpeg image/png image/webp image/avif image/gif image/heic image/heif)

  # The refetch ladder (issue #1803). The strike cap is the column's own, on
  # `RemoteImage`. `@refetch_backoff_seconds` must stay clear of
  # `MediaRefetcher`'s tick or the two beat against each other and the ladder
  # silently runs at half speed.
  @refetch_backoff_seconds 300
  @refetch_batch 20

  @doc "The per-file ceiling (bytes) a fetched picture may not exceed."
  def max_bytes, do: Application.get_env(:vutuv, :fediverse_media_max_bytes, @max_bytes)

  @doc """
  Whether an ActivityPub `attachment` entry is a picture we would store.

  Read from the declared `mediaType`, not from the URL's extension: the
  extension is a guess about somebody else's server, the declaration is what
  they say it is — and either way `Vutuv.Uploads.Spec` refuses to decode
  anything that is not really an image, so this only decides what is worth a
  request.
  """
  def image_attachment?(%{"url" => url} = attachment) when is_binary(url) do
    type = attachment["mediaType"]
    is_binary(type) and String.downcase(type) in @image_types
  end

  def image_attachment?(_attachment), do: false

  @doc """
  Records the pictures a cached post carries, without fetching anything yet.

  Up to `RemoteImage.max_per_post/0` of them, in the author's order, each with
  its alt text. `sensitive` comes from the post — the author's flag or their
  content warning — because that decision is theirs and applies to every
  picture under it.

  Returns the rows so the caller can hand them to `fetch_async/1`.
  """
  def record_attachments(remote_post, attachments, sensitive?) when is_list(attachments) do
    attachments
    |> Enum.filter(&image_attachment?/1)
    |> Enum.take(RemoteImage.max_per_post())
    |> Enum.with_index()
    |> Enum.flat_map(fn {attachment, position} ->
      attrs = %{
        source_uri: attachment["url"],
        position: position,
        alt: attachment["name"],
        sensitive: sensitive?,
        moderation: ImageScans.initial_state()
      }

      case Repo.insert(
             RemoteImage.changeset(%RemoteImage{remote_post_id: remote_post.id}, attrs),
             on_conflict: :nothing,
             conflict_target: [:remote_post_id, :source_uri]
           ) do
        # The id is minted in Elixir, so on a conflict the struct carries an id
        # no row has: reading it back is what tells the two apart, and
        # `List.wrap/1` drops the re-delivered picture we already hold.
        {:ok, %RemoteImage{id: id}} -> List.wrap(Repo.get(RemoteImage, id))
        _ -> []
      end
    end)
  end

  @doc """
  Re-syncs a cached post's pictures from an author's edit (`Update`).

  Authors edit for exactly the reasons that change pictures: they add the
  content warning they forgot, fix an alt text, drop a photo, add one. Until
  this existed an edit changed only the post's words, so a warning added after
  publishing left the pictures here uncovered — the author asked for a cover and
  our copy ignored them — and a picture they removed stayed on the card.

  Removed pictures go with their files, surviving ones take the author's current
  order, description and warning, and newly named ones are recorded (and
  returned) so the caller fetches them like any other.
  """
  def sync_attachments(remote_post, attachments, sensitive?) when is_list(attachments) do
    wanted =
      attachments
      |> Enum.filter(&image_attachment?/1)
      |> Enum.take(RemoteImage.max_per_post())

    drop_pictures(remote_post, Enum.map(wanted, & &1["url"]))

    wanted
    |> Enum.with_index()
    |> Enum.each(&restate_picture(remote_post, &1, sensitive?))

    record_attachments(remote_post, attachments, sensitive?)
  end

  defp drop_pictures(remote_post, kept_urls) do
    ids =
      Repo.all(
        from(i in RemoteImage,
          where: i.remote_post_id == ^remote_post.id and i.source_uri not in ^kept_urls,
          select: i.id
        )
      )

    # Files first: after the delete there is no row left to name them.
    Enum.each(ids, &RemoteMedia.delete_post_image/1)
    Repo.delete_all(from(i in RemoteImage, where: i.id in ^ids))
  end

  defp restate_picture(remote_post, {attachment, position}, sensitive?) do
    case Repo.get_by(RemoteImage, remote_post_id: remote_post.id, source_uri: attachment["url"]) do
      %RemoteImage{} = image ->
        image
        |> RemoteImage.changeset(%{
          position: position,
          alt: attachment["name"],
          sensitive: sensitive?
        })
        |> Repo.update()

      nil ->
        :ok
    end
  end

  @doc """
  Downloads and stores what `record_attachments/3` recorded, in the background.

  Fire and forget: a picture that never arrives simply never renders, and the
  post is already readable without it. Off in tests.
  """
  def fetch_async(images) when is_list(images) do
    if fetching?() and images != [] do
      Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn -> Enum.each(images, &fetch_now/1) end)
    end

    :ok
  end

  @doc """
  Fetches one recorded picture, stores it and hands it to the AI gate.

  Returns `:ok` when the bytes landed, `:skip` for every refusal — an
  unreachable server, a non-image, one over the ceiling, a file that does not
  decode, or a post that was deleted while we were downloading. A refusal is
  not an error anybody needs to see: the post renders without that picture,
  which is the same thing a reader gets while the gate is still thinking.

  The download takes as long as a stranger's server takes, and the post can go
  in the meantime — expiry, an upstream `Delete`, a member's report. So the row
  is written with `stale_error_field:`, which turns the vanished row into an
  ordinary changeset error rather than an `Ecto.StaleEntryError`: without it
  this raised, took the post's *remaining* pictures down with it (they share
  one task), and left the bytes it had just written on disk after the sweep
  that deleted the post had already run. Losing that race now deletes the file
  again, so nothing is left at rest for a post nobody can reach.
  """
  def fetch_now(%RemoteImage{} = image) do
    case try_and_record(image) do
      :ok -> :ok
      {:error, _reason} -> :skip
    end
  end

  @doc """
  The same fetch, saying **why** it failed (issue #1803).

  `fetch_now/1` folds every refusal into one `:skip`, which is all its callers
  can use. The ladder has to tell two of them apart, because they deserve
  opposite treatment:

    * `{:error, :unreachable}` — the server did not answer, or answered with
      something other than a `200`. A bad minute, so it is worth another try.
    * `{:error, :unusable}` — the bytes are here and they are not a picture we
      can store: a video its server declares as an image, a file over the
      ceiling, something that does not decode. Trying again fetches the same
      thing, so this gives up at once.

  A post deleted mid-download is `:unusable` too, deliberately: there is no row
  left to hold a picture, and a retry would only race the sweep again.
  """
  def try_once(%RemoteImage{} = image) do
    with {:ok, bytes} <- download(image.source_uri),
         {:ok, %{file: file, width: width, height: height}} <-
           RemoteMedia.store_post_image(bytes, image.id),
         {:ok, _stored} <- store_file(image, %{file: file, width: width, height: height}) do
      ImageScans.enqueue("remote_post_image", image.id, nil, file)
      :ok
    else
      # `RemoteMedia.store_post_image/2` answers `{:error, reason}` for bytes
      # that do not decode as an image, which is the same permanent answer under
      # a different word. Only a server's silence earns another try.
      {:error, :unreachable} -> {:error, :unreachable}
      _other -> {:error, :unusable}
    end
  end

  @doc """
  The pictures whose bytes never arrived and are due another try (issue #1803),
  least recently tried first.

  Least recently tried is the ordering every sweeper here uses, so the clock has
  to move on **every** outcome — see `refetch_due/1`. Among the never-tried it
  breaks ties **newest first**: an attempt that died with its slot leaves the
  clock null, and serving the oldest of those first would leave the picture
  somebody is looking at right now behind a three-week-old backlog.

  Two conditions are worth reading twice. **A refusal is not a failed
  download**: the gate looked at those bytes and said no, so asking for them
  again is the one thing we must not do — `nil` is the spelling it used before
  it wrote `"rejected"`, and both are excluded by name rather than left to
  SQL's NULL rules, which would drop the null silently and for the wrong
  reason. And a row is not due until `@refetch_backoff_seconds` after its
  **insert** when it has never been stamped, so this cannot race the first
  attempt, which is still running for a second or two after the row appears.
  """
  def due_refetches(limit \\ @refetch_batch) do
    now = DateTime.utc_now(:second)
    cutoff = DateTime.add(now, -@refetch_backoff_seconds, :second)
    fresh = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -@refetch_backoff_seconds, :second)

    from(i in RemoteImage,
      where: is_nil(i.file),
      where: i.fetch_failures < ^RemoteImage.max_fetch_failures(),
      where: not is_nil(i.moderation) and i.moderation != "rejected",
      where:
        (is_nil(i.fetch_attempted_at) and i.inserted_at < ^fresh) or
          i.fetch_attempted_at < ^cutoff,
      order_by: [asc_nulls_first: i.fetch_attempted_at, desc: i.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Tries every due picture once and returns how many were attempted.

  **The clock moves on every outcome, including the ones that did nothing.** A
  row this cannot finish would otherwise be due again on the next run — nothing
  about it changes in a few minutes — and because the ordering is oldest-first
  it would hold the front of every batch for ever, spending the whole cap on
  work that can never complete. That is the deadlock #1316 shipped, and the test
  for it asserts the due query no longer returns such a row after one pass.

  **No per-host cap**, unlike `Vutuv.Fediverse.refresh_counts/1`: that one
  re-asks the same object for a week and needs one, while a picture here costs
  at most `RemoteImage.max_fetch_failures/0` requests ever and then leaves the
  queue for good, so the total is bounded by construction. A cap applied to an
  already-sorted, already-capped batch is the amplifier that starves the healthy
  rows behind one blocked host.
  """
  def refetch_due(limit \\ @refetch_batch) do
    due = due_refetches(limit)

    Enum.each(due, &try_and_record/1)
    length(due)
  end

  # One attempt with the ladder written down. **Both** the first fetch and the
  # sweeper take this path, which is what makes it one ladder: an attempt that
  # dies with its slot leaves the same trace as a refused one, and no row can
  # sit in the queue with no clock on it.
  defp try_and_record(%RemoteImage{} = image) do
    outcome = try_once(image)
    record(image, outcome)
    outcome
  end

  # Nothing to stamp on success: the row leaves the queue by having a file, and
  # writing to it here would be a guaranteed zero-row update.
  defp record(_image, :ok), do: :ok

  # The bytes are here and we cannot store them — a video its server calls an
  # image, one over the ceiling, something that does not decode. They will be
  # the same bytes tomorrow, so the tries are spent at once rather than fetching
  # that video five more times.
  defp record(image, {:error, :unusable}),
    do: stamp(image, RemoteImage.max_fetch_failures())

  # A server having a bad day is asked less and less rather than every run.
  defp record(image, {:error, :unreachable}),
    do: stamp(image, image.fetch_failures + 1)

  # By id rather than through the struct in hand: the retention sweep can delete
  # the row while this run is in flight, and `Repo.update/1` would then raise
  # inside the sweeper. A vanished row is simply no rows updated.
  #
  # It writes the fetch state and nothing else. `moderation` is the **gate's**
  # column and this is not the gate — folding "the download gave up" into it
  # would give a verdict two writers and, worse, would be unreadable on an
  # installation whose pictures are born `"approved"` because it runs no vision
  # model.
  defp stamp(%RemoteImage{} = image, failures) do
    Repo.update_all(
      from(i in RemoteImage, where: i.id == ^image.id),
      set: [fetch_failures: failures, fetch_attempted_at: DateTime.utc_now(:second)]
    )

    :ok
  end

  defp store_file(%RemoteImage{} = image, attrs) do
    case image
         |> RemoteImage.changeset(attrs)
         |> Repo.update(stale_error_field: :id) do
      {:ok, stored} ->
        {:ok, stored}

      {:error, _changeset} ->
        RemoteMedia.delete_post_image(image.id)
        {:error, :unusable}
    end
  end

  @doc """
  Fetches an account's avatar and hands it to the gate, when the actor document
  names one we have not already stored.

  `icon_url` is compared against the stored `avatar_source`, so a re-delivered
  actor document (they arrive on every `Update`) does not re-download an
  unchanged picture — and a changed one does.
  """
  def fetch_avatar_now(account, icon_url) when is_binary(icon_url) do
    with true <- account.avatar_source != icon_url,
         {:ok, bytes} <- download(icon_url),
         {:ok, %{file: file}} <- RemoteMedia.store_avatar(bytes, account.id),
         {:ok, _stored} <- store_avatar_file(account, icon_url, file) do
      ImageScans.enqueue("remote_avatar", account.id, nil, file)
      :ok
    else
      _ -> :skip
    end
  end

  def fetch_avatar_now(_account, _icon_url), do: :skip

  # An account can be purged (or its server blocked) while its avatar is
  # downloading; see `store_file/2` for why that must not raise or leave bytes.
  defp store_avatar_file(account, icon_url, file) do
    case account
         |> Ecto.Changeset.change(
           avatar: file,
           avatar_source: icon_url,
           avatar_moderation: ImageScans.initial_state()
         )
         |> Repo.update(stale_error_field: :id) do
      {:ok, stored} ->
        {:ok, stored}

      {:error, _changeset} ->
        RemoteMedia.delete_avatar(account.id)
        :error
    end
  end

  @doc "The background twin of `fetch_avatar_now/2`. Off in tests."
  def fetch_avatar_async(account, icon_url) do
    if fetching?() and is_binary(icon_url) do
      Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn ->
        fetch_avatar_now(account, icon_url)
      end)
    end

    :ok
  end

  @doc """
  The picture URL an actor document names, when it names one we would fetch.
  ActivityPub puts it under `icon`, either as an object or a bare URL.
  """
  def actor_icon_url(%{"icon" => %{"url" => url}}) when is_binary(url), do: url
  def actor_icon_url(%{"icon" => url}) when is_binary(url), do: url
  def actor_icon_url(_doc), do: nil

  defp fetching?, do: Application.get_env(:vutuv, :fediverse_media_fetch, true)

  # The same fence every outbound request here wears, with the ceiling doing the
  # real work: a picture's size is the attack, so the stream is halted at the
  # limit rather than buffered and measured afterwards.
  defp download(url) when is_binary(url) do
    with {:parse, %URI{scheme: "https", host: host}} when is_binary(host) <-
           {:parse, URI.parse(url)},
         {:ssrf, false} <- {:ssrf, Vutuv.Ssrf.resolves_to_internal?(host)} do
      request(url)
    else
      # The address itself is refused, and it does not change between tries.
      _ -> {:error, :unusable}
    end
  end

  defp download(_url), do: {:error, :unusable}

  # The two failures the refetcher tells apart (issue #1803): a server that did
  # not answer with a picture may answer next time, while bytes we cannot store
  # will be the same bytes tomorrow.
  defp request(url) do
    case Req.get(options(url)) do
      # Strictly under: the collector *halts* the stream at the ceiling, so a
      # body that lands exactly on it is as likely a file cut in half as a file
      # that happens to be that size. Refusing both is the honest read — and
      # either way it is this picture's own size, not a bad minute.
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        if byte_size(body) < max_bytes(), do: {:ok, body}, else: {:error, :unusable}

      _other ->
        {:error, :unreachable}
    end
  end

  defp options(url) do
    Keyword.merge(
      [
        url: url,
        headers: [{"accept", "image/*"}, {"user-agent", Http.user_agent()}],
        receive_timeout: 10_000,
        connect_options: [timeout: 2_000],
        retry: false,
        redirect: false,
        decode_body: false,
        into: Vutuv.Http.capped_collector(max_bytes())
      ],
      Application.get_env(:vutuv, :fediverse_req_options, [])
    )
  end
end
