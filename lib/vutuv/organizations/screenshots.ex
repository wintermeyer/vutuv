defmodule Vutuv.Organizations.Screenshots do
  @moduledoc """
  An organization page's **homepage screenshot**: capture the website the page
  names, off the request path, and show it on the page.

  **Durable queue.** Each organization that names a `website_url` gets one
  `organization_screenshots` row (see
  `Vutuv.Organizations.OrganizationScreenshot`), which is both the job and the
  result. Because the queue is a table, a crash or a re-deploy mid-capture
  loses nothing: `Vutuv.Organizations.ScreenshotWorker` drains it on a poll,
  `resume_stuck/0` re-queues a job that died in flight, and a transient failure
  retries with exponential backoff up to `max_attempts/0`.

  **DRY.** Nothing about the capture is new here. The redirect resolution, the
  SSRF guard, the consent blocker and the browser frame are
  `Vutuv.PageScreenshot.capture_resolved/2` (shared with profile links and the
  post queue); storage, the served URL, the pixelated preview and deletion are
  `Vutuv.Screenshot` — this row is the scope, exactly like a `Url` — so the
  stored file is the same 400×264 AVIF thumb with the `/images/screenshot.png`
  fallback. The capture is gated by the `:generate_screenshots` flag (intranet
  installs run air-gapped).

  **Redirects are followed here, unlike in a post.** A homepage that answers
  `301` from the apex to `www.`, or from `http` to `https`, is the ordinary
  case; insisting on a plain `200` (what `Vutuv.Posts.Screenshots` does, where a
  redirect usually means a shortener or a login wall) would leave most
  organizations without a picture. Every hop is SSRF-vetted all the same.

  **The capture is held until the AI scan releases it** (`kind:
  "organization_screenshot"`), like every other image on the site. It waits in
  the quarantine tree, which no web server can reach, and the page meanwhile
  shows the pixelated preview (issue #1720) rather than an empty tile. The scan
  has **no owning member**: an organization page belongs to a team, not to one
  person, and nobody chose these pixels — so a rejection notifies nobody, the
  same ownerless shape the remote-image scans use.
  """

  import Ecto.Query

  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Organizations.Organization
  alias Vutuv.Organizations.OrganizationScreenshot
  alias Vutuv.Organizations.ScreenshotWorker
  alias Vutuv.PageScreenshot
  alias Vutuv.Repo
  alias Vutuv.ScreenshotBlocklist

  require Logger

  @max_attempts 5
  @batch 5
  # Reset a `capturing` job a crash orphaned after this long (the capture
  # ceiling is ~40s; 10 min is comfortably past any live capture).
  @stuck_after_seconds 600

  # The on-page display size of the stored thumb (the AVIF is 2× this, see
  # `Vutuv.Uploads.Spec` `:screenshot`); mirrors the profile-links recipe.
  @display_width 400
  @display_height 264

  @doc "Retry cap before a transient failure is marked permanently `failed`."
  def max_attempts, do: @max_attempts

  ## Enqueue

  @doc """
  Reconciles an organization's screenshot job with the website it now names.
  Enqueues a `pending` job when there is a `website_url` (refreshing it when the
  URL changed); removes the job and its files when the page no longer names one.
  Called after every create and edit; idempotent, and a no-op when the URL is
  unchanged so a routine edit does not re-shoot the homepage.
  """
  def reconcile(%Organization{} = organization) do
    job = Repo.get_by(OrganizationScreenshot, organization_id: organization.id)

    case qualifying_url(organization) do
      {:ok, url} -> enqueue(organization, job, url)
      :none -> cancel(job)
    end
  end

  # An archived page is unreachable, so a capture would be a browser run spent
  # on something nobody can see. Everything else with a website qualifies,
  # including a still-`pending` claim: by the time the domain is verified the
  # picture is already there.
  defp qualifying_url(%Organization{status: "archived"}), do: :none

  defp qualifying_url(%Organization{website_url: url}) when is_binary(url) do
    case String.trim(url) do
      "" -> :none
      trimmed -> {:ok, trimmed}
    end
  end

  defp qualifying_url(%Organization{}), do: :none

  # An unchanged URL keeps whatever the job already holds — a `ready` capture is
  # not re-shot because somebody fixed a typo in the description, and a `failed`
  # one is not retried forever by repeated saves.
  defp enqueue(_organization, %OrganizationScreenshot{url: url} = job, url), do: {:ok, job}

  defp enqueue(organization, job, url) do
    # A new URL means the old capture pictures the wrong site: drop its files
    # before the row starts naming the new one, so nothing is left orphaned on
    # disk and no stale thumb can be served against the new job.
    if job, do: delete_files(job)

    (job || %OrganizationScreenshot{organization_id: organization.id})
    |> OrganizationScreenshot.enqueue_changeset(url)
    |> Repo.insert_or_update()
    |> case do
      {:ok, job} ->
        ScreenshotWorker.nudge()
        {:ok, job}

      error ->
        error
    end
  end

  defp cancel(nil), do: {:ok, nil}

  defp cancel(%OrganizationScreenshot{} = job) do
    Repo.delete(job)
    delete_files(job)
    {:ok, nil}
  end

  @doc """
  Removes a job's screenshot files. The DB cascade drops the row when a page is
  deleted, but never the bytes on disk, so `Organizations.delete_organization/1`
  reads the job first and calls this after.
  """
  def delete_files(%OrganizationScreenshot{} = job), do: Vutuv.Screenshot.delete(job)

  ## Reads

  @doc """
  The organization's screenshot job, or `nil`. What the page renders from —
  `Vutuv.Screenshot.url/2` and `pixelated_url/1` both take this row as their
  scope.
  """
  def for_organization(%Organization{id: id}),
    do: Repo.get_by(OrganizationScreenshot, organization_id: id)

  @doc """
  Whether there is a picture worth putting on the page: a released capture whose
  file is really on disk, or the pixelated stand-in for one the AI scan has not
  judged yet.

  Asked off the **resolved URL**, not off the column, for the same reason
  `<.link_thumb>` does it: a row can name a capture whose bytes are gone (issue
  #1443), and `Vutuv.Screenshot.url/2` answers the placeholder for it. A card
  that is nothing but the bundled grey rectangle reads as a broken image, so the
  organization page drops the whole card instead of showing one.
  """
  def showable?(nil), do: false

  def showable?(%OrganizationScreenshot{} = job) do
    not is_nil(Vutuv.Screenshot.pixelated_url(job)) or
      Vutuv.Screenshot.url({job.screenshot, job}, :thumb) != Vutuv.Screenshot.placeholder_url()
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

    from(s in OrganizationScreenshot,
      where:
        s.status == "pending" and s.attempts < @max_attempts and
          (is_nil(s.next_attempt_at) or s.next_attempt_at <= ^now),
      order_by: [asc: s.inserted_at],
      limit: ^Keyword.get(opts, :limit, @batch)
    )
    |> Repo.all()
  end

  @doc """
  Re-queues jobs a crash left stuck in `capturing`. Returns the count reset.
  Called on worker boot and each drain — the durability backstop.
  """
  def resume_stuck do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -@stuck_after_seconds, :second)

    {count, _} =
      from(s in OrganizationScreenshot, where: s.status == "capturing" and s.updated_at < ^cutoff)
      |> Repo.update_all(set: [status: "pending", updated_at: NaiveDateTime.utc_now(:second)])

    count
  end

  @doc """
  Drops every job whose URL is on the blocklist today, row and stored files
  alike, and returns how many went — the one-shot cleanup after an admin adds an
  entry (`Vutuv.ScreenshotBlocklist`), run from a release together with the
  other two halves:

      bin/vutuv eval "Vutuv.Release.purge_blocklisted_screenshots()"

  A dropped job leaves the page showing its plain website link, which is what a
  page with no capture shows anyway.
  """
  def purge_blocklisted do
    OrganizationScreenshot
    |> Repo.all()
    |> Enum.filter(&ScreenshotBlocklist.blocked?(&1.url))
    |> Enum.map(fn job ->
      Repo.delete(job)
      delete_files(job)
    end)
    |> length()
  end

  defp process(%OrganizationScreenshot{} = job, capture) do
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

  # A property of the target that won't change on retry: an SSRF-refused
  # internal host, a page this installation never shoots, or a redirect chain
  # that leads nowhere usable. Everything else — a missing, crashed or
  # timed-out Chromium, an unreachable proxy, a host that does not resolve right
  # now — is transient and retries with backoff until the cap.
  defp permanent_failure?(:internal_target), do: true
  defp permanent_failure?(:blocklisted), do: true
  defp permanent_failure?(:too_many_redirects), do: true
  defp permanent_failure?(:bad_redirect), do: true
  defp permanent_failure?(_reason), do: false

  defp capture_and_store(%OrganizationScreenshot{} = job) do
    with {:ok, framed_path} <- PageScreenshot.capture_resolved(job.url, job.id) do
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

  defp mark_capturing(%OrganizationScreenshot{} = job) do
    {:ok, job} = job |> Ecto.Changeset.change(status: "capturing") |> Repo.update()
    job
  end

  defp mark_ready(%OrganizationScreenshot{} = job, file_name, width, height) do
    # A fresh capture starts in AI-moderation limbo: it is rendered only once
    # the scan releases it, otherwise a screenshot of an NSFW page would bypass
    # the upload gate (`Vutuv.Moderation.ImageScans`).
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

    # `owner_user_id: nil` — an organization page belongs to a team, and nobody
    # picked these pixels, so there is no member to notify or to re-enqueue this
    # against (the ownerless shape the remote-image scans use).
    if moderation != "approved" do
      ImageScans.enqueue("organization_screenshot", ready.id, nil, ready.screenshot)
    end

    ready
  end

  defp mark_retry(%OrganizationScreenshot{} = job, reason) do
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

  defp mark_failed(%OrganizationScreenshot{} = job, reason) do
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
    do:
      "organization screenshot failed for organization #{job.organization_id} " <>
        "(#{job.url}): #{inspect(reason)}"
end
