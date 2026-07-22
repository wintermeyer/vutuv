defmodule Vutuv.Posts.ReviewCovers do
  @moduledoc """
  Fetches what the catalogues know about a **book review's ISBN** — Open
  Library's cover image and edition facts (`pages`, `publisher`), plus an
  audiobook's running time (`duration_minutes`, `Vutuv.AudiobookLength`) —
  off the request path: `Vutuv.Posts` calls `reconcile/1`
  after every post create/update, and a review whose `cover_status` is
  `pending` (a new or changed ISBN — `Vutuv.Posts.PostReview` sets that in
  its changeset) gets a background fetch under `Vutuv.TaskSupervisor`.

  Gated by the `:fetch_book_metadata` flag (air-gapped installs fetch
  nothing and the card renders its placeholder tile; tests keep it off and
  stub HTTP via `:book_covers_req_options`). Not a durable queue on purpose —
  a cover is decorative, a fetch lost to a restart is simply retried on the
  next edit, and a `failed` status keeps the card rendering without a cover.

  A fetched cover is an **external image shown publicly**, so it enters the
  AI-moderation gate like any upload: stored `pending`
  (`Vutuv.Moderation.ImageScans`), served through the authorizing proxy only
  once released, deleted on rejection (`Vutuv.Moderation.ImageSubjects`).
  """

  import Ecto.Query

  alias Vutuv.AudiobookLength
  alias Vutuv.BookMetadata
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostReview
  alias Vutuv.Repo
  alias Vutuv.ReviewCover

  require Logger

  @req_options_key :book_covers_req_options

  @doc "Whether this installation fetches book metadata/covers at all."
  def enabled?, do: Application.get_env(:vutuv, :fetch_book_metadata, true)

  @doc "Removes a review's stored cover files (post deletion, moderation)."
  defdelegate delete_files(review), to: ReviewCover

  @doc """
  Starts the background cover fetch for a post whose review is waiting on
  one; a no-op for every other post (and with `:fetch_book_metadata` off —
  the review then stays `pending`, harmless and re-checked on the next
  edit). Expects `post.review` preloaded, as the create/update paths do.
  """
  def reconcile(%Post{review: %PostReview{kind: "book", cover_status: "pending"} = review})
      when is_binary(review.identifier) do
    if enabled?() do
      Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn -> fetch(review) end)
    end

    :ok
  end

  def reconcile(%Post{}), do: :ok

  @doc """
  The fetch itself (synchronous — `reconcile/1` wraps it in a task): stores
  the ISBN's edition details, then pulls its cover from Open Library and
  flips the review to `ready` (entering moderation limbo) or `failed` (no
  cover known, network trouble). Guarded on the review still carrying the
  fetched ISBN, so a concurrent edit wins over a slow fetch.
  """
  def fetch(%PostReview{kind: "book", identifier: isbn} = review) when is_binary(isbn) do
    fetch_details(review, isbn)

    case get_cover(isbn) do
      {:ok, bytes} -> store(review, bytes)
      :error -> mark(review, cover_status: "failed")
    end
  rescue
    exception ->
      Logger.warning(
        "review cover fetch failed for review #{review.id} (#{isbn}): #{Exception.message(exception)}"
      )

      mark(review, cover_status: "failed")
  end

  @doc """
  Re-fetches every stored book cover (and, since the fetch is one pass, the
  edition details with it — this is also the backfill for reviews written
  before `pages`/`publisher` existed) and purges the private originals that
  fetches before v7.122.4 kept (see `Vutuv.ReviewCover`) — the maintenance
  path that replaces the `Vutuv.Uploads.Regenerator` for covers, since there
  is deliberately nothing left to re-derive from locally. Run it once after
  a `Vutuv.Uploads.Spec` change to the `:review_cover` version:

      mix vutuv.review_covers.refresh
      bin/vutuv eval "Vutuv.Release.refresh_review_covers()"

  Open Library asks callers not to crawl its cover API (100 requests per IP
  per 5 minutes), so this waits `:delay` ms between fetches — 3s by default,
  comfortably inside that budget. Returns a `%{refetched: n, skipped: n}`
  summary; a review whose fetch fails keeps its current cover status and is
  simply retried on the next run.
  """
  def refresh_all(opts \\ []) do
    delay = Keyword.get(opts, :delay, 3_000)

    reviews =
      Repo.all(
        from(r in PostReview,
          where: r.kind == "book" and not is_nil(r.identifier) and r.cover_status != "none",
          order_by: [asc: r.id]
        )
      )

    Logger.info("review covers: refreshing #{length(reviews)} cover(s)")

    Enum.reduce(reviews, %{refetched: 0, skipped: 0}, &refresh_one(&1, &2, delay))
  end

  defp refresh_one(review, summary, delay) do
    ReviewCover.purge_original(review)

    if enabled?() do
      fetch(review)
      # Courtesy pacing, not correctness: Open Library asks callers not to
      # crawl the cover API (100 requests per IP per 5 minutes).
      delay > 0 and Process.sleep(delay)
      %{summary | refetched: summary.refetched + 1}
    else
      %{summary | skipped: summary.skipped + 1}
    end
  end

  # Page count and publisher from Open Library's edition record
  # (`Vutuv.BookMetadata`), plus the running time for an audiobook review
  # (`Vutuv.AudiobookLength`, a library catalogue — Open Library records no
  # durations). Best-effort by design: an edition nobody knows details for
  # simply keeps the card it has, and a failure here must not cost the review
  # its cover, so this rescues on its own instead of riding fetch/1's rescue.
  defp fetch_details(review, isbn) do
    case known_details(review, isbn) do
      [] -> :ok
      details -> mark(review, details)
    end
  rescue
    exception ->
      Logger.warning(
        "review details fetch failed for review #{review.id} (#{isbn}): #{Exception.message(exception)}"
      )

      :ok
  end

  defp known_details(review, isbn) do
    edition =
      case BookMetadata.edition_details(isbn) do
        {:ok, %{pages: pages, publisher: publisher}} -> [pages: pages, publisher: publisher]
        :error -> []
      end

    # Only an audiobook review asks for a running time: a print ISBN has
    # none, so the catalogue request would be spent for nothing.
    duration =
      if review.medium == "audiobook",
        do: [duration_minutes: AudiobookLength.minutes(isbn)],
        else: []

    Enum.reject(edition ++ duration, fn {_key, value} -> is_nil(value) end)
  end

  defp get_cover(isbn) do
    # default=false turns Open Library's 1x1 placeholder into a plain 404.
    [
      url: "https://covers.openlibrary.org/b/isbn/#{isbn}-L.jpg?default=false",
      receive_timeout: 15_000,
      retry: false
    ]
    |> Keyword.merge(Application.get_env(:vutuv, @req_options_key, []))
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: bytes}} when is_binary(bytes) and bytes != "" ->
        {:ok, bytes}

      _other ->
        :error
    end
  end

  defp store(review, bytes) do
    case ReviewCover.store_binary(bytes, review) do
      {:ok, file} -> announce_stored(review, file)
      {:error, _reason} -> mark(review, cover_status: "failed")
    end
  end

  defp announce_stored(review, file) do
    moderation = ImageScans.initial_state()

    case mark(review, cover: file, cover_status: "ready", cover_moderation: moderation) do
      :ok when moderation == "approved" ->
        # Open feeds/profiles re-render the card with the cover.
        Vutuv.Posts.broadcast_review_cover_ready(review.post_id)
        :ok

      :ok ->
        # Moderation limbo: the scan verdict announces (or deletes) it later.
        ImageScans.enqueue("review_cover", review.id, owner_id(review), file)
        :ok

      :stale ->
        # An edit changed the ISBN while we fetched: its own reconcile
        # re-fetches; drop what we stored for the outdated ISBN.
        ReviewCover.delete_files(review)
        :ok
    end
  end

  # Atomically updates the review iff it still carries the fetched ISBN
  # (identifier is pinned in the WHERE); `:stale` when an edit won the race.
  defp mark(%PostReview{} = review, set) do
    now = NaiveDateTime.utc_now(:second)

    {count, _} =
      from(r in PostReview, where: r.id == ^review.id and r.identifier == ^review.identifier)
      |> Repo.update_all(set: Keyword.put(set, :updated_at, now))

    if count == 1, do: :ok, else: :stale
  end

  defp owner_id(%PostReview{post_id: post_id}) do
    Repo.one(from(p in Post, where: p.id == ^post_id, select: p.user_id))
  end
end
