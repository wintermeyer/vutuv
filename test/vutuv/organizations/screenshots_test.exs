defmodule Vutuv.Organizations.ScreenshotsTest do
  @moduledoc """
  The organization homepage-screenshot subsystem: enqueue/refresh/cancel
  reconciliation off `organizations.website_url`, the durable queue's state
  transitions and backoff, the stuck-job re-queue, and the AI-moderation gate
  that decides whether the page may show the capture yet. The real
  headless-Chromium capture is stubbed through the `capture:` seam, so these run
  without launching a browser.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Organizations
  alias Vutuv.Organizations.OrganizationScreenshot
  alias Vutuv.Organizations.Screenshots
  alias Vutuv.ScreenshotBlocklist

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      # Back to the value `config/test.exs` sets, never `delete_env`: the
      # function's own default is `true`, so an absent key reads as "on" and
      # every later test would start resolving DNS for real.
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  # A capture stub that "succeeds" with a fixed stored filename + size.
  defp ok_capture,
    do: fn _job -> {:ok, %{screenshot: "0123456789ab.avif", width: 400, height: 264}} end

  defp failing_capture(reason), do: fn _job -> {:error, reason} end

  defp job_for(organization), do: Screenshots.for_organization(organization)

  describe "reconcile/1" do
    test "claiming a page queues a capture of the website it names" do
      {organization, _owner} = active_organization()

      assert %OrganizationScreenshot{status: "pending", url: "https://acme.example", attempts: 0} =
               job_for(organization)
    end

    test "an edit that leaves the website alone does not re-shoot it" do
      {organization, _owner} = active_organization()
      job = job_for(organization)

      {:ok, ready} =
        job |> Ecto.Changeset.change(status: "ready", screenshot: "aa.avif") |> Repo.update()

      {:ok, organization} =
        Organizations.update_organization(organization, %{"description" => "Now with a story."})

      unchanged = job_for(organization)
      assert unchanged.id == ready.id
      assert unchanged.status == "ready"
      assert unchanged.screenshot == "aa.avif"
    end

    test "a new website re-queues the same row and drops the old capture" do
      {organization, _owner} = active_organization()

      {:ok, _ready} =
        organization
        |> job_for()
        |> Ecto.Changeset.change(
          status: "ready",
          screenshot: "aa.avif",
          moderation: "approved",
          attempts: 3
        )
        |> Repo.update()

      {:ok, organization} =
        Organizations.update_organization(organization, %{
          "website_url" => "https://moved.example"
        })

      job = job_for(organization)
      assert job.status == "pending"
      assert job.url == "https://moved.example"
      # The old capture's state goes with the old URL: leaving `screenshot` or
      # `moderation` behind would let a page serve a picture of the site it just
      # stopped naming.
      assert job.screenshot == nil
      assert job.moderation == nil
      assert job.attempts == 0
    end

    test "clearing the website drops the job entirely" do
      {organization, _owner} = active_organization()
      assert job_for(organization)

      {:ok, organization} =
        Organizations.update_organization(organization, %{"website_url" => ""})

      refute job_for(organization)
    end

    test "archiving a page drops its job — nobody can reach the page any more" do
      {organization, _owner} = active_organization()
      assert job_for(organization)

      {:ok, archived} = Organizations.archive_organization(organization)

      refute job_for(archived)
    end
  end

  describe "deliver_due/1" do
    test "a successful capture lands as a ready row" do
      {organization, _owner} = active_organization()

      Screenshots.deliver_due(force: true, capture: ok_capture())

      job = job_for(organization)
      assert job.status == "ready"
      assert job.screenshot == "0123456789ab.avif"
      assert job.width == 400
      assert job.height == 264
      assert job.captured_at
    end

    test "with the capture flag off nothing is captured and the row stays pending" do
      {organization, _owner} = active_organization()

      Screenshots.deliver_due(capture: ok_capture())

      assert job_for(organization).status == "pending"
    end

    test "a transient failure retries with backoff, a permanent one gives up at once" do
      {transient, _owner} = active_organization()
      Screenshots.deliver_due(force: true, capture: failing_capture(:chromium_not_found))

      job = job_for(transient)
      assert job.status == "pending"
      assert job.attempts == 1
      assert job.next_attempt_at
      assert job.last_error =~ "chromium_not_found"

      {permanent, _owner} = active_organization(%{"website_url" => "https://other.example"})
      # Only the fresh job is due — the retried one is parked behind its backoff.
      Screenshots.deliver_due(force: true, capture: failing_capture(:internal_target))

      job = job_for(permanent)
      assert job.status == "failed"
      assert job.attempts == 1
      assert job.next_attempt_at == nil
    end

    test "a job past the retry cap is not picked up again" do
      {organization, _owner} = active_organization()

      {:ok, _spent} =
        organization
        |> job_for()
        |> Ecto.Changeset.change(attempts: Screenshots.max_attempts())
        |> Repo.update()

      assert Screenshots.list_due() == []
    end
  end

  describe "resume_stuck/0" do
    test "a job a crash left mid-capture comes back, and only after the cutoff" do
      {organization, _owner} = active_organization()
      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600, :second)

      Repo.update_all(OrganizationScreenshot, set: [status: "capturing"])
      assert Screenshots.list_due() == []
      # Calibration: a job that only *just* started capturing is left alone, so
      # the test below proves the age check and not merely the status reset.
      assert Screenshots.resume_stuck() == 0

      Repo.update_all(OrganizationScreenshot, set: [updated_at: long_ago])

      assert Screenshots.resume_stuck() == 1
      assert job_for(organization).status == "pending"
    end
  end

  describe "the AI moderation gate" do
    setup do
      Application.put_env(:vutuv, :moderate_images, true)
      on_exit(fn -> Application.put_env(:vutuv, :moderate_images, false) end)
      :ok
    end

    test "a fresh capture is held pending and queues an ownerless scan" do
      {organization, _owner} = active_organization()

      Screenshots.deliver_due(force: true, capture: ok_capture())

      job = job_for(organization)
      assert job.status == "ready"
      assert job.moderation == "pending"
      refute OrganizationScreenshot.ready?(job)

      scan = ImageScans.latest_for("organization_screenshot", job.id)
      assert scan.fingerprint == job.screenshot
      # A page belongs to a team and nobody chose these pixels, so a rejection
      # has no member to notify.
      assert scan.owner_user_id == nil
    end

    test "with moderation off the capture is released on the spot" do
      Application.put_env(:vutuv, :moderate_images, false)
      {organization, _owner} = active_organization()

      Screenshots.deliver_due(force: true, capture: ok_capture())

      job = job_for(organization)
      assert job.moderation == "approved"
      assert OrganizationScreenshot.ready?(job)
    end
  end

  describe "showable?/1" do
    test "no job, and a job with no capture, show nothing" do
      {organization, _owner} = active_organization()

      refute Screenshots.showable?(nil)
      refute Screenshots.showable?(job_for(organization))
    end

    test "a row naming a file that is not on disk shows nothing either" do
      {organization, _owner} = active_organization()

      {:ok, job} =
        organization
        |> job_for()
        |> Ecto.Changeset.change(
          status: "ready",
          screenshot: "0123456789ab.avif",
          moderation: "approved"
        )
        |> Repo.update()

      refute Screenshots.showable?(job)
    end
  end

  describe "purge_blocklisted/0" do
    test "drops the job of a page whose website went on the blocklist" do
      {organization, _owner} = active_organization()
      {keeper, _owner} = active_organization(%{"website_url" => "https://kept.example"})

      Repo.delete_all(ScreenshotBlocklist.Entry)
      {:ok, _entry} = ScreenshotBlocklist.create_entry(%{"pattern" => "acme.example"})

      assert Screenshots.purge_blocklisted() == 1

      refute job_for(organization)
      assert job_for(keeper)
    end
  end
end
