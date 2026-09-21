defmodule Vutuv.Posts.Screenshots do
  @moduledoc """
  The post **link-screenshot** subsystem: when a post carries a single URL and
  no image, capture a screenshot of that page off the request path and store it
  as an attachment shown beside the post.

  **Durable queue.** Each qualifying post gets one `post_screenshots` row (see
  `Vutuv.Posts.PostScreenshot`), which is both the job and the result: a
  `pending` row is work waiting, `capturing` is in flight, `ready` carries the
  stored screenshot, `failed` gave up after its retries, and `skipped` was
  refused for good on the first answer: an SSRF-blocked host, a link that
  redirects off its site (or more than twice on it), or a non-200 target — only
  a plain HTTP 200 is captured. Because the queue is a table, a restart or
  re-deploy loses nothing —
  `Vutuv.Posts.ScreenshotWorker` drains it on a poll, `resume_stuck/0` re-queues
  a job a crash left mid-capture, and a transient failure retries with
  exponential backoff. This is the "re-create if in doubt" guarantee.

  **DRY.** Capture + browser frame + SSRF guard are `Vutuv.PageScreenshot`
  (shared with profile links); storage/URL/delete are `Vutuv.Screenshot` (this
  row is the scope, exactly like a `Url`), so the stored file is the same
  400×264 AVIF thumb with the `/images/screenshot.png` fallback. The capture is
  gated by the `:generate_screenshots` flag (intranet installs run air-gapped).

  **YouTube links don't screenshot.** A watch page always answers with the
  cookie-consent banner, so a capture never shows the video; the worker stores
  the thumbnail YouTube publishes for every video instead, frameless
  (`Vutuv.YoutubeThumbnail`), and falls back to the ordinary capture whenever
  that fetch fails.

  **Cached fediverse posts ride the same queue.** A followed account's post
  (`Vutuv.Fediverse.RemotePost`) qualifies by the same rule — one URL, no
  picture — plus one of its own: never behind the author's content warning /
  sensitive flag (the author closed the lid; an auto-preview would prop it
  open). Its job carries `remote_post_id` instead of `post_id`, and everything
  downstream is shared, with two per-owner differences: the ready-announcement
  (nobody is watching a remote post get captured, so no broadcast) and the AI
  scan's owner (no local member, like the remote-picture scans).
  """

  import Ecto.Query

  alias Vutuv.ChangesetHelpers
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.MediaJobs
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Repo
  alias Vutuv.ScreenshotBlocklist
  alias Vutuv.ScreenshotTrust
  alias Vutuv.SocialFeed.Http
  alias Vutuv.YoutubeThumbnail

  require Logger

  # A bare http(s) URL, mirroring the markdown autolinker
  # (`VutuvWeb.Markdown.autolink_bare_urls/1`).
  @url_regex ~r{https?://[^\s<>]+}

  @max_attempts 5
  # Redirects the probe follows within one site. Two is what a newspaper's short
  # link takes to its article (taz.de: `/!6201058` → `/!6201058/` → the titled
  # path); a longer chain is more likely a consent or login detour than a page.
  @max_redirect_hops 2
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
  longer qualifies. Called after every create/update; idempotent. Takes a
  member's `Post` or a cached fediverse `RemotePost` — both own the same job
  row, keyed by their own foreign key.
  """
  def reconcile(%Post{} = post) do
    # force: the caller's struct may carry a stale `:screenshot` (nil from create
    # time) even after a prior reconcile inserted the row — reload it so a second
    # reconcile updates the row instead of colliding on the unique post_id.
    post
    |> Repo.preload([:images, :screenshot], force: true)
    |> reconcile_loaded()
  end

  def reconcile(%RemotePost{} = post) do
    post
    |> Repo.preload([:images, :screenshot], force: true)
    |> reconcile_loaded()
  end

  defp reconcile_loaded(post) do
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
  `/settings`, `/admin` or `/system` area, or at a blocklisted page
  (`Vutuv.ScreenshotBlocklist.blocked?/1`, e.g. `heise.de`), does **not**
  qualify — a blocklisted page never screenshots, so no job is even enqueued
  and the post simply shows its link.

  A cached fediverse post plays by the same rules plus one of its own: a post
  its author put behind a content warning (or flagged sensitive) never
  qualifies — the card renders it as a closed lid, and an auto-fetched preview
  image would prop that lid open.
  """
  def qualifying_url(%Post{images: [], body: body}), do: sole_url_target(body)
  def qualifying_url(%Post{images: images}) when is_list(images), do: :none

  def qualifying_url(%RemotePost{images: [], content_text: text} = post) do
    if RemotePost.warned?(post), do: :none, else: sole_url_target(text)
  end

  def qualifying_url(%RemotePost{images: images}) when is_list(images), do: :none

  defp sole_url_target(body) do
    case extract_urls(body) do
      [url] -> qualify(url)
      _ -> :none
    end
  end

  defp qualify(url) do
    if own_internal_url?(url) or ScreenshotBlocklist.blocked?(url),
      do: :none,
      else: {:ok, url}
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
  # `/system` area. `Fediverse.local_host?/1` is the one "is this us" test
  # (endpoint-derived host, `www.` and case folded), so the skip is correct on
  # any third-party installation.
  defp own_internal_url?(url) do
    uri = URI.parse(url)
    Fediverse.local_host?(uri.host) and internal_path?(uri.path)
  end

  defp internal_path?(nil), do: false

  defp internal_path?(path) do
    Enum.any?(@internal_path_roots, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  # The refresh/keep clauses match on the preloaded `:screenshot` alone, so
  # they serve both owners; only a fresh insert needs to know whose key to set.
  defp enqueue(%{screenshot: %PostScreenshot{url: url} = existing}, url) do
    # Same URL already queued/captured: leave it (a `ready` row stays ready).
    {:ok, existing}
  end

  defp enqueue(%{screenshot: %PostScreenshot{} = existing}, url) do
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

  defp enqueue(%RemotePost{id: remote_post_id, screenshot: nil}, url) do
    %PostScreenshot{remote_post_id: remote_post_id}
    |> PostScreenshot.enqueue_changeset(url)
    |> Repo.insert()
  end

  # No longer qualifies: drop the row and its files (the render path already
  # ignores it once the post has images, but keeping the row/file would leak).
  # Unlike post deletion, nothing cascades here, so delete the row explicitly.
  defp cancel(%{screenshot: nil}), do: :ok

  defp cancel(%{screenshot: %PostScreenshot{} = existing}) do
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
  Deletes the stored screenshot files of cached fediverse posts that are about
  to be deleted. Called from the one media-wipe chokepoint every cached-post
  deletion goes through (`Vutuv.Fediverse`), so an upstream `Delete`, a report,
  a narrowing edit, the retention sweep and an instance block all shed the
  files; the rows themselves cascade with the `fediverse_posts` foreign key.
  """
  def delete_for_remote_posts(remote_post_ids) when is_list(remote_post_ids) do
    from(ps in PostScreenshot, where: ps.remote_post_id in ^remote_post_ids)
    |> Repo.all()
    |> Enum.each(&delete/1)
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
  Puts a job that gave up back in the queue: `pending`/`capturing`/`failed`/
  `skipped` → `pending` with a clean slate (attempts reset, backoff and last
  error cleared), so the next drain picks it up. An author-`dismissed` tombstone
  and a `ready` row are refused with `{:error, :not_requeueable}` — dismissing is
  the author's decision, and a ready row is not work.

  Nothing else revives a `failed` or `skipped` row: the retry cap is final, so a
  job that burned its attempts while capture itself was broken (a hanging page
  that Chromium never bounded, say) would stay dead forever once the environment
  recovered, and a skipped link is only worth asking again once the site or this
  installation's rules changed. This is the admin's hand-back, from
  `/admin/screenshots`.
  """
  def requeue(%PostScreenshot{status: status} = job)
      when status in ~w(pending capturing failed skipped) do
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

  @doc """
  Puts every finished job whose URL is a YouTube video back in the queue, so
  the worker replaces its stored capture with the video's own thumbnail
  (`Vutuv.YoutubeThumbnail`) — the one-shot backfill for captures from before
  that existed, which all show YouTube's consent banner. `ready`, `failed` and
  `skipped` rows alike get a clean pending slate; an author-`dismissed`
  tombstone stays dismissed (their call, and the thumbnail may be exactly what
  they removed). Returns the number re-queued. On a release, run it via
  `Vutuv.Release.requeue_youtube_screenshots/0`.
  """
  def requeue_youtube do
    from(ps in PostScreenshot, where: ps.status in ["ready", "failed", "skipped"])
    |> Repo.all()
    |> Enum.filter(&match?({:ok, _id}, YoutubeThumbnail.video_id(&1.url)))
    |> Enum.map(fn job ->
      {:ok, _requeued} =
        job
        |> Ecto.Changeset.change(
          status: "pending",
          attempts: 0,
          next_attempt_at: nil,
          last_error: nil
        )
        |> Repo.update()
    end)
    |> length()
  end

  @doc """
  Drops every job — queued, ready, failed or skipped — whose URL is on the blocklist
  today, row and stored files alike, and returns how many went.

  The one-shot cleanup after an entry is added (`Vutuv.ScreenshotBlocklist`):
  such a capture is exactly the consent-banner picture the entry exists to
  prevent, and nothing would ever replace it, since `reconcile/1` only
  re-captures when a post's URL changes. Dropping the row is what `reconcile/1`
  itself does for a post that stopped qualifying, so the card falls back to
  showing the plain link. Run from a release together with the profile-link
  half:

      bin/vutuv eval "Vutuv.Release.purge_blocklisted_screenshots()"
  """
  def purge_blocklisted do
    PostScreenshot
    |> Repo.all()
    |> Enum.filter(&ScreenshotBlocklist.blocked?(&1.url))
    |> Enum.map(fn job ->
      Repo.delete(job)
      delete(job)
    end)
    |> length()
  end

  @doc "Loads one job by id, raising when it is gone (the admin views' reads)."
  def get_job!(id), do: Repo.get!(PostScreenshot, id)

  @doc """
  The screenshots ready to render for these member posts, as
  `%{post_id => %PostScreenshot{}}` — captured **and** released by the image
  scan (`PostScreenshot.ready?/1`), nothing else. One query for a page of
  posts; a post with no capture, a pending one or a held one is simply absent.
  """
  def ready_by_post_ids([]), do: %{}

  def ready_by_post_ids(post_ids) when is_list(post_ids) do
    from(s in PostScreenshot, where: s.post_id in ^post_ids and s.status == "ready")
    |> Repo.all()
    |> Enum.filter(&PostScreenshot.ready?/1)
    |> Map.new(&{&1.post_id, &1})
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

    # The media-job row (issue #2103) wraps the capture itself, which is the
    # Chromium run an operator asks about. A retryable failure still closes its
    # row as failed: the next attempt is its own job, and a row per attempt is
    # what makes "this URL has failed nine times" visible.
    media_job =
      MediaJobs.start("screenshot",
        subject_type: "post_screenshot",
        subject_id: job.id,
        user_id: owner_user_id(job),
        post_id: job.post_id
      )

    case capture.(job) do
      {:ok, %{screenshot: file, width: width, height: height} = captured} ->
        # Only a page capture can be trusted; the YouTube thumbnail is the
        # uploader's artwork, not the site's, and carries no such key. A
        # capture that does not say is scanned.
        trusted? = Map.get(captured, :trusted, false)

        MediaJobs.finish(media_job,
          detail: if(trusted?, do: "captured, trusted site: not scanned", else: "captured")
        )

        mark_ready(job, file, width, height, trusted?)

      {:error, reason} ->
        MediaJobs.fail(media_job, reason)

        if permanent_failure?(reason),
          do: mark_skipped(job, reason),
          else: mark_retry(job, reason)
    end
  end

  # A property of the target that won't change on retry, so the job is skipped
  # rather than failed: an SSRF-refused internal host, a blocklisted page
  # (`:blocklisted`, one we never shoot), a redirect the probe would not follow
  # (`:redirect`), or a `4xx` non-200 answer (`{:bad_status, _}`) other than 408
  # and 429, which ask to be tried later. Everything else — a `5xx` server
  # error, an unreachable probe, a missing/crashed/timed-out Chromium — is
  # transient and retries with backoff until the cap.
  defp permanent_failure?(:internal_target), do: true
  defp permanent_failure?(:blocklisted), do: true
  # The page check saw a consent/login/ad wall and put the site on the
  # blocklist: a retry would be refused by the blocklist anyway.
  defp permanent_failure?(:obstructed), do: true
  defp permanent_failure?(:redirect), do: true
  defp permanent_failure?({:bad_status, status}), do: status not in [408, 429]
  defp permanent_failure?(_reason), do: false

  # The real capture. A YouTube video link stores the thumbnail YouTube itself
  # publishes (a watch-page capture only ever shows the consent banner); every
  # other link — and any YouTube fetch trouble — takes the Chromium path.
  defp capture_and_store(%PostScreenshot{} = job) do
    case youtube_capture(job) do
      {:ok, result} -> {:ok, result}
      :fallback -> page_capture_and_store(job)
    end
  end

  # The YouTube branch: `{:ok, result}` with the stored thumbnail, or
  # `:fallback` — not a YouTube video URL, a video oEmbed doesn't know
  # (deleted, private), fetch or store trouble — and the caller then captures
  # the page like any other link.
  defp youtube_capture(%PostScreenshot{} = job) do
    with {:ok, video_id} <- YoutubeThumbnail.video_id(job.url),
         {:ok, bytes} <- YoutubeThumbnail.fetch(video_id) do
      store_thumbnail(job, bytes)
    else
      :error -> :fallback
    end
  end

  # Stored raw — no browser frame: the thumbnail is the video's artwork, not a
  # captured web page, so browser chrome around it would be a lie.
  defp store_thumbnail(%PostScreenshot{} = job, bytes) do
    tmp = Path.join(System.tmp_dir!(), "yt_thumb_#{job.id}.jpg")

    try do
      File.write!(tmp, bytes)
      upload = %Plug.Upload{content_type: "image/jpeg", filename: "#{job.id}.jpg", path: tmp}

      case Vutuv.Screenshot.store({upload, job}) do
        {:ok, file_name} ->
          {:ok, %{screenshot: file_name, width: @display_width, height: @display_height}}

        {:error, _reason} ->
          :fallback
      end
    after
      File.rm(tmp)
    end
  end

  # The classic capture: capture only a link that ends in a plain HTTP 200, then
  # reuse the shared pipeline and store through the same uploader profile links
  # use. Chromium is handed the address the probe ended at, so it shoots the
  # page that answered and never walks a redirect the probe did not vet. The
  # blocklist is asked about the named URL before any probe (a row queued before
  # its entry existed), and `capture_framed/2` asks again about the target.
  # Returns the stored filename + display size, and whether the browser only
  # showed trusted sites (`Vutuv.ScreenshotTrust`).
  defp page_capture_and_store(%PostScreenshot{} = job) do
    with false <- ScreenshotBlocklist.blocked?(job.url),
         {:ok, target} <- ensure_http_ok(job.url),
         {:ok, framed_path, trusted?} <- Vutuv.PageScreenshot.capture_framed(target, job.id) do
      upload = %Plug.Upload{
        content_type: "image/webp",
        filename: "#{job.id}.webp",
        path: framed_path
      }

      result =
        case Vutuv.Screenshot.store({upload, job}, trusted: trusted?) do
          {:ok, file_name} ->
            {:ok,
             %{
               screenshot: file_name,
               width: @display_width,
               height: @display_height,
               trusted: trusted?
             }}

          {:error, reason} ->
            {:error, reason}
        end

      File.rm(framed_path)
      result
    else
      true -> {:error, :blocklisted}
      refused -> refused
    end
  end

  # Config key for the probe's Req options; tests inject a `plug:` through it,
  # exactly like the social-feed clients' per-provider seams.
  @probe_req_options_key :post_screenshot_req_options

  @doc """
  `{:ok, target}` when `url` ends in a plain **HTTP 200**, where `target` is the
  address that answered; otherwise `{:error, reason}` and no screenshot is taken.
  A `redirect: false` GET probe (what a browser would get) runs in the worker
  before Chromium. It follows at most #{@max_redirect_hops} redirects, and only
  within the same site (the host itself or its `www.` alias): a newspaper's short
  link to its own article is the same page, while a bounce to another host lands
  on a login or consent wall or a shortener's target. Anything else — a redirect
  off the site or one hop too many, a 404, any other non-200 answer — is refused,
  leaving the post to show the plain link. Off the request path, so the probe
  never slows a save.

  Reasons distinguish permanent from transient (for the retry cap): a refused
  redirect is `:redirect` and a `4xx` `{:bad_status, status}` (both permanent —
  they won't become a 200 for this URL — except a 408 or 429, which ask to be
  tried later), a `5xx` is `{:server_error, status}` and a transport failure
  `:probe_failed` (both transient — the origin may recover). An internal host,
  at the start or at any hop, is caught here as `:internal_target` (the same
  permanent outcome `Vutuv.PageScreenshot.capture_framed/2` would give) and
  **never probed**, so this is not an SSRF request.
  """
  def ensure_http_ok(url), do: probe_hop(url, @max_redirect_hops)

  defp probe_hop(url, hops_left) do
    if Vutuv.Ssrf.resolves_to_internal?(URI.parse(url).host) do
      {:error, :internal_target}
    else
      case classify(probe(url)) do
        :ok -> {:ok, url}
        {:redirect, resp} -> follow(url, resp, hops_left)
        refused -> refused
      end
    end
  end

  defp classify({:ok, %Req.Response{status: 200}}), do: :ok
  defp classify({:ok, %Req.Response{status: s} = resp}) when s in 300..399, do: {:redirect, resp}

  defp classify({:ok, %Req.Response{status: s}}) when s in 400..499,
    do: {:error, {:bad_status, s}}

  defp classify({:ok, %Req.Response{status: s}}), do: {:error, {:server_error, s}}
  # Couldn't reach the target to check — transient, retried like a Chromium timeout.
  defp classify(_error), do: {:error, :probe_failed}

  # A redirect is followed only while hops are left and only to the same site.
  # The target must still be a plain web address: `web_url?/1` refuses the
  # backslash and userinfo tricks that make `URI.parse/1` name a different host
  # than a browser would open.
  defp follow(url, resp, hops_left) do
    next = Vutuv.PageScreenshot.redirect_target(url, resp)

    if hops_left > 0 and is_binary(next) and ChangesetHelpers.web_url?(next) and
         site(next) == site(url),
       do: probe_hop(next, hops_left - 1),
       else: {:error, :redirect}
  end

  # The www. alias is the same site; any other subdomain is not. The same fold
  # the trusted-sites check applies, so the subsystem reads a host one way.
  defp site(url), do: ScreenshotTrust.Host.canonical(URI.parse(url).host)

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
      # The body is never read, so Req must not spend work on (or fail over)
      # decoding it — a member link answering malformed `application/json`
      # would otherwise error the probe.
      decode_body: false,
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

  defp mark_ready(%PostScreenshot{} = job, file_name, width, height, trusted?) do
    # A fresh capture starts in AI-moderation limbo: it is announced (and
    # rendered) only once the scan releases it — otherwise a screenshot of an
    # NSFW page would bypass the upload gate (Vutuv.Moderation.ImageScans).
    # A trusted site's capture is the exception (Vutuv.ScreenshotTrust).
    moderation = ScreenshotTrust.initial_moderation(trusted?)

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

    if moderation != "approved" do
      ImageScans.enqueue("post_screenshot", ready.id, owner_user_id(ready), ready.screenshot)
    end

    # Announced whether or not the gate still has it (issue #1927). It used to
    # wait for the verdict, which was right while a held capture drew nothing:
    # since issue #1720 it draws its mosaic preview, so the capture landing is
    # itself something to show, and the card that has been sitting there
    # picture-less since the post arrived can stop being picture-less.
    announce(ready, :ready)

    ready
  end

  @doc """
  Tells whoever is drawing this capture that it moved: `:ready` when there is
  something new to show of it, `:gone` when there is not any more.

  **Two audiences, one decision, and it lives here** — the module that owns the
  row — because a capture hangs off either kind of post: a member's own reaches
  their followers' feeds and their profile, a cached post's reaches whoever has
  a card of it open, over the one topic those six surfaces already listen on.
  `Vutuv.Moderation.ImageSubjects` announces the same row's verdicts and calls
  this rather than keeping a second copy of the routing, which had already
  drifted apart on the rejection.

  `:gone` matters because a rejection deletes the very file an open card may be
  showing as its mosaic preview; the cached-post side has no second word for it,
  where both verdicts are the same "re-read what you draw".
  """
  def announce(screenshot, verdict \\ :ready)

  def announce(%PostScreenshot{post_id: post_id}, :ready) when is_binary(post_id),
    do: Vutuv.Posts.broadcast_screenshot_ready(post_id)

  def announce(%PostScreenshot{post_id: post_id}, :gone) when is_binary(post_id),
    do: Vutuv.Posts.broadcast_screenshot_removed(post_id)

  def announce(%PostScreenshot{remote_post_id: id}, _verdict) when is_binary(id),
    do: Fediverse.broadcast_remote_images_changed(id)

  # A row the retention sweep has taken between the verdict and this.
  def announce(_screenshot, _verdict), do: :ok

  # The AI scan's owning member: the post's author, or nobody for a remote
  # post's capture (the same ownerless shape the "remote_post_image" and
  # "remote_avatar" scans use).
  # One column, not the whole post: the body alone can be kilobytes, and this
  # is now also read at the *start* of a capture (for the media-job row).
  defp owner_user_id(%PostScreenshot{post_id: nil}), do: nil

  defp owner_user_id(%PostScreenshot{post_id: post_id}),
    do: Repo.one(from(p in Post, where: p.id == ^post_id, select: p.user_id))

  defp mark_retry(%PostScreenshot{} = job, reason) do
    attempts = job.attempts + 1
    status = if attempts >= @max_attempts, do: "failed", else: "pending"

    Logger.warning(outcome_message("failed", job, reason))

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

  defp mark_skipped(%PostScreenshot{} = job, reason) do
    Logger.info(outcome_message("skipped", job, reason))

    {:ok, job} =
      job
      |> Ecto.Changeset.change(
        status: "skipped",
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

  defp outcome_message(outcome, job, reason),
    do: "post screenshot #{outcome} for #{owner_label(job)} (#{job.url}): #{inspect(reason)}"

  defp owner_label(%PostScreenshot{post_id: post_id}) when is_binary(post_id),
    do: "post #{post_id}"

  defp owner_label(%PostScreenshot{remote_post_id: remote_post_id}),
    do: "remote post #{remote_post_id}"

  ## Admin reads

  # What the admin queue holds: work waiting or in flight, and the jobs that ran
  # out of retries and need an admin. A skipped job is none of those.
  @queue_statuses ~w(pending capturing failed)

  @doc """
  One page of the admin queue view: the unfinished jobs (`pending` / `capturing`
  / `failed`), newest first, with the owning post + author (or the cached
  remote post + its account) preloaded. Returns `{rows, total}`.
  Author-`dismissed` tombstones are neither unfinished work nor a gallery item,
  so they are excluded from every admin view.
  """
  def queue_page(params) do
    page(
      from(ps in PostScreenshot, where: ps.status in @queue_statuses),
      params,
      desc: :inserted_at
    )
  end

  @doc """
  One page of the admin's skipped list: the links refused for good (see
  `PostScreenshot`), newest first, preloaded like `queue_page/1`. Kept apart
  from the queue because none of it is work, and kept visible because the
  sites that refuse every capture are what the blocklist is fed from.
  """
  def skipped_page(params) do
    page(from(ps in PostScreenshot, where: ps.status == "skipped"), params, desc: :inserted_at)
  end

  @doc """
  One page of the admin gallery: captured (`ready`) screenshots, newest capture
  first, post + author preloaded (member **or** organization). Returns
  `{rows, total}`.
  """
  def gallery_page(params) do
    page(from(ps in PostScreenshot, where: ps.status == "ready"), params, desc: :captured_at)
  end

  @doc "Count of queued, ready and skipped jobs, for the admin tab labels."
  def counts do
    by_status =
      from(ps in PostScreenshot, group_by: ps.status, select: {ps.status, count(ps.id)})
      |> Repo.all()
      |> Map.new()

    %{
      queue: by_status |> Map.take(@queue_statuses) |> Map.values() |> Enum.sum(),
      ready: Map.get(by_status, "ready", 0),
      skipped: Map.get(by_status, "skipped", 0)
    }
  end

  defp page(base, params, order) do
    total = Repo.aggregate(base, :count)

    rows =
      base
      |> order_by(^order)
      |> Vutuv.Pages.paginate(params, total, @per_page)
      # Both kinds of author: an organization post gets a link screenshot the
      # same way a member's does (issue #1334), and `Vutuv.Posts.path/1` — which
      # the gallery links every row with — matches on whichever one is
      # preloaded. With only `:user` the page raised on the first such row.
      |> preload(post: [:user, :organization], remote_post: :remote_account)
      |> Repo.all()

    {rows, total}
  end
end
