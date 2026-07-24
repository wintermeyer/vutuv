defmodule Vutuv.Posts.Screenshots do
  @moduledoc """
  The post **link-screenshot** subsystem: when a post carries a single URL and
  no image, capture a screenshot of that page off the request path and store it
  as an attachment shown beside the post.

  **Durable queue.** Each qualifying post gets one `post_screenshots` row (see
  `Vutuv.Posts.PostScreenshot`), which is both the job and the result: a
  `pending` row is work waiting, `capturing` is in flight, `ready` carries the
  stored screenshot, `failed` gave up (retries exhausted, or a permanent refusal:
  an SSRF-blocked host, a redirecting link, or a non-200 target — only a plain
  HTTP 200 is captured). Because the queue is a table, a restart or re-deploy
  loses nothing —
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

  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Repo
  alias Vutuv.SocialFeed.Http

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

  # This installation's own login-walled / internal areas: a screenshot of them
  # would only ever be a login redirect or an admin/internal page, never useful
  # preview content, so a single-URL post pointing at one is not screenshotted.
  # These path roots are all reserved slugs (`Vutuv.Accounts.ReservedSlugs`).
  @internal_path_roots ~w(/settings /admin /system)

  @doc """
  The single URL a post should be screenshotted for, or `:none`. Qualifies only
  with **no image attachment** and **exactly one** distinct `http(s)` URL in the
  body (surrounding text is fine). A URL pointing at this installation's own
  `/settings`, `/admin` or `/system` area does **not** qualify.
  """
  def qualifying_url(%Post{images: [], body: body}), do: sole_url_target(body)
  def qualifying_url(%Post{images: images}) when is_list(images), do: :none

  defp sole_url_target(body) do
    case extract_urls(body) do
      [url] -> qualify(url)
      _ -> :none
    end
  end

  defp qualify(url) do
    if own_internal_url?(url), do: :none, else: {:ok, url}
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

  # True when `url` points at this installation's own `/settings`, `/admin` or
  # `/system` area. The host is derived from the endpoint (never a literal
  # `vutuv.de`), so the skip is correct on any third-party installation; `www.`
  # is stripped from both sides so the two forms compare equal.
  defp own_internal_url?(url) do
    uri = URI.parse(url)
    own_host?(uri.host) and internal_path?(uri.path)
  end

  defp own_host?(nil), do: false
  defp own_host?(host), do: strip_www(host) == strip_www(VutuvWeb.Endpoint.host())

  defp strip_www(host), do: host |> String.downcase() |> String.replace_prefix("www.", "")

  defp internal_path?(nil), do: false

  defp internal_path?(path) do
    Enum.any?(@internal_path_roots, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

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

  @doc """
  The author's "this screenshot is bad, remove it" action from the post edit
  page (a capture spoiled by a cookie banner, say). Purges the stored files and
  tombstones the row as `dismissed`: the render path shows nothing but a `ready`
  row, `list_due/1` only picks up `pending` rows, and `enqueue/2` leaves an
  existing row for the same URL untouched — so a plain re-save never re-captures
  it. Changing the post's single URL still re-captures (a different page is a
  new screenshot), and dropping the link cancels the row entirely, both via
  `reconcile/1`.
  """
  def dismiss(%PostScreenshot{} = post_screenshot) do
    delete(post_screenshot)

    post_screenshot
    |> Ecto.Changeset.change(
      status: "dismissed",
      screenshot: nil,
      width: nil,
      height: nil,
      captured_at: nil,
      last_error: nil,
      moderation: nil
    )
    |> Repo.update()
  end

  @doc """
  Puts a job that gave up back in the queue: `pending`/`capturing`/`failed` →
  `pending` with a clean slate (attempts reset, backoff and last error cleared),
  so the next drain picks it up. An author-`dismissed` tombstone and a `ready`
  row are refused with `{:error, :not_requeueable}` — dismissing is the author's
  decision, and a ready row is not work.

  Nothing else revives a `failed` row: the retry cap is final, so a job that
  burned its attempts while capture itself was broken (a hanging page that
  Chromium never bounded, say) would stay dead forever once the environment
  recovered. This is the admin's hand-back, from `/admin/screenshots`.
  """
  def requeue(%PostScreenshot{status: status} = job)
      when status in ~w(pending capturing failed) do
    job
    |> Ecto.Changeset.change(
      status: "pending",
      attempts: 0,
      next_attempt_at: nil,
      last_error: nil
    )
    |> Repo.update()
  end

  def requeue(%PostScreenshot{}), do: {:error, :not_requeueable}

  @doc "Loads one job by id, raising when it is gone (the admin views' reads)."
  def get_job!(id), do: Repo.get!(PostScreenshot, id)

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

      {:error, reason} ->
        if permanent_failure?(reason),
          do: mark_failed(job, reason),
          else: mark_retry(job, reason)
    end
  end

  # A property of the target that won't change on retry: an SSRF-refused internal
  # host, a link that redirects (`:redirect`), or a `4xx` non-200 answer
  # (`{:bad_status, _}`). Everything else — a `5xx` server error, an unreachable
  # probe, a missing/crashed/timed-out Chromium — is transient and retries with
  # backoff until the cap.
  defp permanent_failure?(:internal_target), do: true
  defp permanent_failure?(:redirect), do: true
  defp permanent_failure?({:bad_status, _status}), do: true
  defp permanent_failure?(_reason), do: false

  # The real capture: capture only a plain HTTP-200 link, then reuse the shared
  # pipeline and store through the same uploader profile links use. Returns the
  # stored filename + display size.
  defp capture_and_store(%PostScreenshot{} = job) do
    with :ok <- ensure_http_ok(job.url),
         {:ok, framed_path} <- Vutuv.PageScreenshot.capture_framed(job.url, job.id) do
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

  # Config key for the probe's Req options; tests inject a `plug:` through it,
  # exactly like the social-feed clients' per-provider seams.
  @probe_req_options_key :post_screenshot_req_options

  @doc """
  `:ok` only when `url` answers a plain **HTTP 200**; otherwise `{:error, reason}`
  and no screenshot is taken. A `redirect: false` GET probe (what a browser would
  get) runs in the worker before Chromium, so a link that redirects, 404s or gives
  any other non-200 answer is skipped — a bounce lands on a login/consent wall or
  a shortener's target, a 404/5xx isn't the linked page — leaving the post to show
  the plain link. Off the request path, so the probe never slows a save.

  Reasons distinguish permanent from transient (for the retry cap): a `3xx` is
  `:redirect` and a `4xx` `{:bad_status, status}` (both permanent — they won't
  become a 200 for this URL), a `5xx` is `{:server_error, status}` and a transport
  failure `:probe_failed` (both transient — the origin may recover). An internal
  host is caught here as `:internal_target` (the same permanent outcome
  `Vutuv.PageScreenshot.capture_framed/2` would give) and **never probed**, so this
  is not an SSRF request.
  """
  def ensure_http_ok(url) do
    if Vutuv.Ssrf.resolves_to_internal?(URI.parse(url).host) do
      {:error, :internal_target}
    else
      classify(probe(url))
    end
  end

  defp classify({:ok, %Req.Response{status: 200}}), do: :ok
  defp classify({:ok, %Req.Response{status: s}}) when s in 300..399, do: {:error, :redirect}

  defp classify({:ok, %Req.Response{status: s}}) when s in 400..499,
    do: {:error, {:bad_status, s}}

  defp classify({:ok, %Req.Response{status: s}}), do: {:error, {:server_error, s}}
  # Couldn't reach the target to check — transient, retried like a Chromium timeout.
  defp classify(_error), do: {:error, :probe_failed}

  # Only the status line is read, never the body, so drop it during receipt at a
  # small ceiling: a hostile member link could otherwise stream an unbounded
  # body into memory (scan finding F15).
  @probe_max_body_bytes 64 * 1024

  defp probe(url) do
    [
      url: url,
      receive_timeout: 5_000,
      connect_options: [timeout: 3_000],
      retry: false,
      redirect: false,
      into: Vutuv.Http.capped_collector(@probe_max_body_bytes),
      headers: [{"user-agent", Http.user_agent()}]
    ]
    |> Keyword.merge(Application.get_env(:vutuv, @probe_req_options_key, []))
    |> Req.get()
  end

  defp mark_capturing(%PostScreenshot{} = job) do
    {:ok, job} = job |> Ecto.Changeset.change(status: "capturing") |> Repo.update()
    job
  end

  defp mark_ready(%PostScreenshot{} = job, file_name, width, height) do
    # A fresh capture starts in AI-moderation limbo: it is announced (and
    # rendered) only once the scan releases it — otherwise a screenshot of an
    # NSFW page would bypass the upload gate (Vutuv.Moderation.ImageScans).
    moderation = ImageScans.initial_state()

    {:ok, ready} =
      job
      |> Ecto.Changeset.change(
        status: "ready",
        screenshot: file_name,
        width: width,
        height: height,
        captured_at: DateTime.utc_now(:second),
        last_error: nil,
        moderation: moderation
      )
      |> Repo.update()

    if moderation == "approved" do
      # Open feeds/profiles upgrade the card to show the screenshot with no reload.
      Vutuv.Posts.broadcast_screenshot_ready(ready.post_id)
    else
      post = Repo.get!(Post, ready.post_id)
      ImageScans.enqueue("post_screenshot", ready.id, post.user_id, ready.screenshot)
    end

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
  Author-`dismissed` tombstones are neither unfinished work nor a gallery item,
  so they are excluded from both admin views.
  """
  def queue_page(params) do
    page(
      from(ps in PostScreenshot, where: ps.status not in ["ready", "dismissed"]),
      params,
      desc: :inserted_at
    )
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
      where: ps.status != "dismissed",
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
