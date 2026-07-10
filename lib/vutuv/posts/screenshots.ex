defmodule Vutuv.Posts.Screenshots do
  @moduledoc """
  The post **link-screenshot** subsystem: when a post carries a single URL and
  no image, capture a screenshot of that page off the request path and store it
  as an attachment shown beside the post.

  **Durable queue.** Each qualifying post gets one `post_screenshots` row (see
  `Vutuv.Posts.PostScreenshot`), which is both the job and the result: a
  `pending` row is work waiting, `capturing` is in flight, `ready` carries the
  stored screenshot, `failed` gave up (retries exhausted, or a permanent SSRF
  refusal). Because the queue is a table, a restart or re-deploy loses nothing —
  `Vutuv.Posts.ScreenshotWorker` drains it on a poll, `resume_stuck/0` re-queues
  a job a crash left mid-capture, and a transient failure retries with
  exponential backoff. This is the "re-create if in doubt" guarantee.

  **DRY.** Capture + browser frame + SSRF guard are `Vutuv.PageScreenshot`
  (shared with profile links); storage/URL/delete are `Vutuv.Screenshot` (this
  row is the scope, exactly like a `Url`), so the stored file is the same
  400×264 AVIF thumb with the `/images/screenshot.png` fallback. The capture is
  gated by the `:generate_screenshots` flag (intranet installs run air-gapped).
  """

  import Ecto.Query

  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Repo

  require Logger

  # A bare http(s) URL, mirroring the markdown autolinker
  # (`VutuvWeb.Markdown.autolink_bare_urls/1`).
  @url_regex ~r{https?://[^\s<>]+}

  @max_attempts 5
  @batch 5
  # Reset a `capturing` job a crash orphaned after this long (the worker's
  # capture ceiling is ~40s; 10 min is comfortably past any live capture).
  @stuck_after_seconds 600
  # Admin page size — a gallery of thumbnails, so denser than the site-wide 250.
  @per_page 24

  @doc "Retry cap before a transient failure is marked permanently `failed`."
  def max_attempts, do: @max_attempts

  @doc "Admin queue/gallery page size."
  def per_page, do: @per_page

  # The on-page display size of the stored thumb (the AVIF is 2× this, see
  # `Vutuv.Uploads.Spec` `:screenshot`); mirrors the profile-links recipe.
  @display_width 400
  @display_height 264

  ## Detection + enqueue

  @doc """
  Reconciles a post's screenshot job with what the post now is. Enqueues a
  `pending` job when the post carries exactly one URL and no image (refreshing
  the URL if it changed); removes the job (and its files) when the post no
  longer qualifies. Called after every create/update; idempotent.
  """
  def reconcile(%Post{} = post) do
    # force: the caller's struct may carry a stale `:screenshot` (nil from create
    # time) even after a prior reconcile inserted the row — reload it so a second
    # reconcile updates the row instead of colliding on the unique post_id.
    post = Repo.preload(post, [:images, :screenshot], force: true)

    case qualifying_url(post) do
      {:ok, url} -> enqueue(post, url)
      :none -> cancel(post)
    end
  end

  @doc """
  The single URL a post should be screenshotted for, or `:none`. Qualifies only
  with **no image attachment** and **exactly one** distinct `http(s)` URL in the
  body (surrounding text is fine).
  """
  def qualifying_url(%Post{images: images, body: body}) when is_list(images) do
    if images == [] do
      case extract_urls(body) do
        [url] -> {:ok, url}
        _ -> :none
      end
    else
      :none
    end
  end

  @doc "Every distinct bare `http(s)` URL in `body`, trailing punctuation trimmed."
  def extract_urls(body) when is_binary(body) do
    @url_regex
    |> Regex.scan(body)
    |> Enum.map(fn [url | _] -> trim_trailing_punctuation(url) end)
    |> Enum.uniq()
  end

  def extract_urls(_body), do: []

  # A URL at the end of a sentence catches the following `.`/`)`/`,` in the
  # greedy `[^\s<>]+`; drop those so the captured target is the real link.
  defp trim_trailing_punctuation(url), do: String.replace(url, ~r/[)\]}.,;:!?'"]+$/u, "")

  defp enqueue(%Post{screenshot: %PostScreenshot{url: url} = existing}, url) do
    # Same URL already queued/captured: leave it (a `ready` row stays ready).
    {:ok, existing}
  end

  defp enqueue(%Post{screenshot: %PostScreenshot{} = existing}, url) do
    # The single URL changed: re-capture. Reset to pending and clear the old
    # error/backoff; the stored file is replaced in place on the next capture.
    existing
    |> PostScreenshot.enqueue_changeset(url)
    |> Ecto.Changeset.change(attempts: 0, next_attempt_at: nil, last_error: nil)
    |> Repo.update()
  end

  defp enqueue(%Post{id: post_id, screenshot: nil}, url) do
    %PostScreenshot{post_id: post_id}
    |> PostScreenshot.enqueue_changeset(url)
    |> Repo.insert()
  end

  # No longer qualifies: drop the row and its files (the render path already
  # ignores it once the post has images, but keeping the row/file would leak).
  # Unlike post deletion, nothing cascades here, so delete the row explicitly.
  defp cancel(%Post{screenshot: nil}), do: :ok

  defp cancel(%Post{screenshot: %PostScreenshot{} = existing}) do
    Repo.delete(existing)
    delete(existing)
    :ok
  end

  @doc """
  Deletes a screenshot's stored files. The DB row is left to the caller — on
  post deletion it cascades with the post (`Vutuv.Posts.delete_post/1`); on
  reconcile-cancel `cancel/1` deletes the row itself.
  """
  def delete(%PostScreenshot{} = post_screenshot) do
    Vutuv.Screenshot.delete(post_screenshot)
  end

  ## Draining the queue

  @doc """
  Captures every due job. A no-op when `:generate_screenshots` is off (the rows
  stay `pending`), so an air-gapped install and the test suite launch no
  Chromium. `opts`: `capture:` injects the per-row capture function (tests stub
  it), `force:` runs even with the flag off, `limit:` caps the batch.
  """
  def deliver_due(opts \\ []) do
    if Keyword.get(opts, :force, false) or
         Application.get_env(:vutuv, :generate_screenshots, true) do
      resume_stuck()
      capture = Keyword.get(opts, :capture, &capture_and_store/1)
      for job <- list_due(opts), do: process(job, capture)
    end

    :ok
  end

  @doc "The `pending`, retry-due jobs the next drain would pick up, oldest first."
  def list_due(opts \\ []) do
    now = DateTime.utc_now(:second)

    from(ps in PostScreenshot,
      where:
        ps.status == "pending" and ps.attempts < @max_attempts and
          (is_nil(ps.next_attempt_at) or ps.next_attempt_at <= ^now),
      order_by: [asc: ps.inserted_at],
      limit: ^Keyword.get(opts, :limit, @batch)
    )
    |> Repo.all()
  end

  @doc """
  Re-queues jobs a crash left stuck in `capturing`. Returns the count reset.
  Called on worker boot and each poll — the durability backstop.
  """
  def resume_stuck do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -@stuck_after_seconds, :second)

    {count, _} =
      from(ps in PostScreenshot, where: ps.status == "capturing" and ps.updated_at < ^cutoff)
      |> Repo.update_all(set: [status: "pending", updated_at: NaiveDateTime.utc_now(:second)])

    count
  end

  defp process(%PostScreenshot{} = job, capture) do
    job = mark_capturing(job)

    case capture.(job) do
      {:ok, %{screenshot: file, width: width, height: height}} ->
        mark_ready(job, file, width, height)

      # A permanent property of the target (SSRF-refused internal host): give up,
      # like a profile url's `broken?` flag.
      {:error, :internal_target} ->
        mark_failed(job, :internal_target)

      # A transient/environment failure (Chromium missing, crashed, timed out):
      # retry with backoff until the cap.
      {:error, reason} ->
        mark_retry(job, reason)
    end
  end

  # The real capture: reuse the shared pipeline, then store through the same
  # uploader profile links use. Returns the stored filename + display size.
  defp capture_and_store(%PostScreenshot{} = job) do
    with {:ok, framed_path} <- Vutuv.PageScreenshot.capture_framed(job.url, job.id) do
      upload = %Plug.Upload{
        content_type: "image/webp",
        filename: "#{job.id}.webp",
        path: framed_path
      }

      result =
        case Vutuv.Screenshot.store({upload, job}) do
          {:ok, file_name} ->
            {:ok, %{screenshot: file_name, width: @display_width, height: @display_height}}

          {:error, reason} ->
            {:error, reason}
        end

      File.rm(framed_path)
      result
    end
  end

  defp mark_capturing(%PostScreenshot{} = job) do
    {:ok, job} = job |> Ecto.Changeset.change(status: "capturing") |> Repo.update()
    job
  end

  defp mark_ready(%PostScreenshot{} = job, file_name, width, height) do
    {:ok, ready} =
      job
      |> Ecto.Changeset.change(
        status: "ready",
        screenshot: file_name,
        width: width,
        height: height,
        captured_at: DateTime.utc_now(:second),
        last_error: nil
      )
      |> Repo.update()

    # Open feeds/profiles upgrade the card to show the screenshot with no reload.
    Vutuv.Posts.broadcast_screenshot_ready(ready.post_id)
    ready
  end

  defp mark_retry(%PostScreenshot{} = job, reason) do
    attempts = job.attempts + 1
    status = if attempts >= @max_attempts, do: "failed", else: "pending"

    Logger.warning(failure_message(job, reason))

    {:ok, job} =
      job
      |> Ecto.Changeset.change(
        status: status,
        attempts: attempts,
        next_attempt_at: backoff_at(attempts),
        last_error: error_string(reason)
      )
      |> Repo.update()

    job
  end

  defp mark_failed(%PostScreenshot{} = job, reason) do
    Logger.warning(failure_message(job, reason))

    {:ok, job} =
      job
      |> Ecto.Changeset.change(
        status: "failed",
        attempts: job.attempts + 1,
        last_error: error_string(reason)
      )
      |> Repo.update()

    job
  end

  defp backoff_at(attempts) do
    DateTime.add(DateTime.utc_now(:second), trunc(:math.pow(2, attempts)) * 60, :second)
  end

  defp error_string(reason), do: reason |> inspect() |> String.slice(0, 255)

  defp failure_message(job, reason),
    do: "post screenshot failed for post #{job.post_id} (#{job.url}): #{inspect(reason)}"

  ## Admin reads

  @doc """
  One page of the admin queue view: the unfinished jobs (`pending` / `capturing`
  / `failed`), newest first, post + author preloaded. Returns `{rows, total}`.
  """
  def queue_page(params) do
    page(from(ps in PostScreenshot, where: ps.status != "ready"), params, desc: :inserted_at)
  end

  @doc """
  One page of the admin gallery: captured (`ready`) screenshots, newest capture
  first, post + author preloaded. Returns `{rows, total}`.
  """
  def gallery_page(params) do
    page(from(ps in PostScreenshot, where: ps.status == "ready"), params, desc: :captured_at)
  end

  @doc "Count of unfinished vs ready jobs, for the admin tab labels."
  def counts do
    from(ps in PostScreenshot,
      group_by: fragment("? = 'ready'", ps.status),
      select: {fragment("? = 'ready'", ps.status), count(ps.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{queue: 0, ready: 0}, fn
      {true, n}, acc -> %{acc | ready: n}
      {false, n}, acc -> %{acc | queue: n}
    end)
  end

  defp page(base, params, order) do
    total = Repo.aggregate(base, :count)

    rows =
      base
      |> order_by(^order)
      |> Vutuv.Pages.paginate(params, total, @per_page)
      |> preload(post: :user)
      |> Repo.all()

    {rows, total}
  end
end
