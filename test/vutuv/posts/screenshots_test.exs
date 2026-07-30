defmodule Vutuv.Posts.ScreenshotsTest do
  @moduledoc """
  The post link-screenshot subsystem: detection (a single URL, no image),
  enqueue/refresh/cancel reconciliation, the durable queue's state transitions
  and backoff, and the stuck-job re-queue. The real headless-Chromium capture is
  stubbed via the `capture:` seam so these run without launching a browser.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots

  defp user, do: insert(:activated_user)

  # A URL on *this* installation's own host (derived from the endpoint, not a
  # literal vutuv.de), used to test the own-host /settings|/admin|/system skip.
  defp own_url(path), do: "https://#{VutuvWeb.Endpoint.host()}#{path}"

  defp url_post(author, body \\ "Look at this: https://example.com/page"),
    do: create_post!(author, %{body: body})

  # A capture stub that "succeeds" with a fixed stored filename + size.
  defp ok_capture,
    do: fn _job -> {:ok, %{screenshot: "0123456789ab.avif", width: 400, height: 264}} end

  # Route the HTTP-200 probe's Req request at a stub: a bare status, or a full
  # `plug: fn conn -> conn end` responder. Paired with the describe's on_exit.
  defp stub_probe(status) when is_integer(status),
    do: stub_probe(fn conn -> Plug.Conn.send_resp(conn, status, "") end)

  defp stub_probe(fun) when is_function(fun),
    do: Application.put_env(:vutuv, :post_screenshot_req_options, plug: fun)

  # A post whose auto-screenshot has already been captured, stored and released
  # by the AI scan — the state the author sees on the card and wants gone.
  defp ready_post(author) do
    post = url_post(author)
    {:ok, job} = Screenshots.reconcile(post)

    {:ok, ready} =
      job
      |> Ecto.Changeset.change(
        status: "ready",
        screenshot: "0123456789ab.avif",
        moderation: "approved"
      )
      |> Repo.update()

    {post, ready}
  end

  describe "extract_urls/1 + qualifying_url/1 (detection)" do
    test "one bare http(s) URL, surrounding text allowed" do
      assert Screenshots.extract_urls("see https://example.com now") == ["https://example.com"]
    end

    test "trailing sentence punctuation is trimmed off the URL" do
      assert Screenshots.extract_urls("Read (https://example.com/a).") ==
               ["https://example.com/a"]
    end

    test "the same URL twice counts as one" do
      assert Screenshots.extract_urls("https://a.test and https://a.test") == ["https://a.test"]
    end

    test "qualifies: no image + exactly one URL" do
      assert Screenshots.qualifying_url(%Posts.Post{images: [], body: "https://a.test"}) ==
               {:ok, "https://a.test"}
    end

    test "does not qualify: an image is attached" do
      post = %Posts.Post{images: [%PostImage{}], body: "https://a.test"}
      assert Screenshots.qualifying_url(post) == :none
    end

    test "does not qualify: zero or two URLs" do
      assert Screenshots.qualifying_url(%Posts.Post{images: [], body: "no link here"}) == :none

      assert Screenshots.qualifying_url(%Posts.Post{
               images: [],
               body: "https://a.test and https://b.test"
             }) == :none
    end

    test "does not qualify: this installation's own /settings, /admin or /system page" do
      for path <-
            ~w(/settings /settings/privacy /admin /admin/screenshots /system /system/members) do
        body = own_url(path)

        assert Screenshots.qualifying_url(%Posts.Post{images: [], body: body}) == :none,
               "expected #{body} to be excluded from screenshotting"
      end
    end

    test "still qualifies: another site's /admin (only the own host is excluded)" do
      assert Screenshots.qualifying_url(%Posts.Post{
               images: [],
               body: "https://example.com/admin"
             }) == {:ok, "https://example.com/admin"}
    end

    test "still qualifies: the own host on an ordinary path" do
      url = own_url("/some-profile")
      assert Screenshots.qualifying_url(%Posts.Post{images: [], body: url}) == {:ok, url}
    end

    test "does not qualify: a screenshot-blocklisted host (reddit.com + subdomains)" do
      # config/config.exs ships reddit.com on :screenshot_blocked_hosts; a
      # single-URL post pointing at it must not enqueue a job — the capture would
      # only ever be reddit's login/consent wall.
      for url <- ~w(
            https://reddit.com/r/elixir
            https://www.reddit.com/r/elixir/comments/abc
            https://old.reddit.com/r/programming
          ) do
        assert Screenshots.qualifying_url(%Posts.Post{images: [], body: url}) == :none,
               "expected #{url} to be excluded from screenshotting"
      end
    end

    test "the blocklist is config-driven and honours a per-installation override" do
      previous = Application.get_env(:vutuv, :screenshot_blocked_hosts)
      on_exit(fn -> Application.put_env(:vutuv, :screenshot_blocked_hosts, previous) end)
      Application.put_env(:vutuv, :screenshot_blocked_hosts, ["example.com"])

      assert Screenshots.qualifying_url(%Posts.Post{
               images: [],
               body: "https://example.com/page"
             }) == :none

      # A host no longer on the (overridden) list qualifies again.
      assert Screenshots.qualifying_url(%Posts.Post{
               images: [],
               body: "https://reddit.com/r/elixir"
             }) == {:ok, "https://reddit.com/r/elixir"}
    end
  end

  describe "ensure_http_ok/1 (HTTP-200 probe)" do
    setup do
      on_exit(fn -> Application.delete_env(:vutuv, :post_screenshot_req_options) end)
    end

    test "a plain 200 page is allowed through to capture" do
      stub_probe(200)
      assert Screenshots.ensure_http_ok("https://example.com/page") == :ok
    end

    test "a link that HTTP-redirects (3xx) is refused permanently" do
      stub_probe(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://example.com/login")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert Screenshots.ensure_http_ok("https://example.com/page") == {:error, :redirect}
    end

    test "a 404 (any 4xx) is refused permanently" do
      stub_probe(404)

      assert Screenshots.ensure_http_ok("https://example.com/gone") ==
               {:error, {:bad_status, 404}}
    end

    test "a 5xx server error is refused but transient (may recover on retry)" do
      stub_probe(503)

      assert Screenshots.ensure_http_ok("https://example.com/down") ==
               {:error, {:server_error, 503}}
    end
  end

  describe "reconcile/1" do
    test "enqueues a pending job for a single-URL, image-less post" do
      post = url_post(user())
      assert {:ok, %PostScreenshot{}} = Screenshots.reconcile(post)

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.status == "pending"
      assert job.url == "https://example.com/page"
    end

    test "is idempotent: the same URL leaves the job untouched" do
      post = url_post(user())
      {:ok, first} = Screenshots.reconcile(post)
      {:ok, again} = Screenshots.reconcile(post)

      assert first.id == again.id
      assert Repo.aggregate(PostScreenshot, :count) == 1
    end

    test "a changed URL resets the job to pending with the new URL" do
      author = user()
      post = url_post(author, "https://old.test")
      {:ok, job} = Screenshots.reconcile(post)

      # Mark it captured, then change the post's single URL.
      Repo.update!(Ecto.Changeset.change(job, status: "ready", screenshot: "x.avif"))
      {:ok, updated} = Posts.update_post(post, %{body: "https://new.test"})
      Screenshots.reconcile(updated)

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.status == "pending"
      assert job.url == "https://new.test"
    end

    test "drops the job when the post no longer qualifies" do
      author = user()
      post = url_post(author, "https://gone.test")
      {:ok, _job} = Screenshots.reconcile(post)

      {:ok, updated} = Posts.update_post(post, %{body: "no more link"})
      Screenshots.reconcile(updated)

      refute Repo.get_by(PostScreenshot, post_id: post.id)
    end
  end

  describe "dismiss/1 (author removes a bad screenshot)" do
    test "tombstones the row as dismissed and clears the stored file" do
      {_post, ready} = ready_post(user())
      assert PostScreenshot.ready?(ready)

      {:ok, dismissed} = Screenshots.dismiss(ready)

      assert dismissed.status == "dismissed"
      assert dismissed.screenshot == nil
      assert dismissed.captured_at == nil
      refute PostScreenshot.ready?(dismissed)
    end

    test "the worker never picks a dismissed job back up" do
      {_post, ready} = ready_post(user())
      {:ok, _} = Screenshots.dismiss(ready)

      assert Screenshots.list_due() == []
    end

    test "a plain re-save of the same URL leaves the dismissed tombstone in place" do
      {post, ready} = ready_post(user())
      {:ok, _} = Screenshots.dismiss(ready)

      # Editing the body but keeping the single URL reconciles the job; the
      # dismissed tombstone must survive so the removed screenshot stays gone.
      {:ok, updated} =
        Posts.update_post(post, %{body: "New words, same link https://example.com/page"})

      Screenshots.reconcile(updated)

      assert Repo.get_by!(PostScreenshot, post_id: post.id).status == "dismissed"
    end

    test "changing the post's URL re-captures (a new page is a new screenshot)" do
      {post, ready} = ready_post(user())
      {:ok, _} = Screenshots.dismiss(ready)

      {:ok, updated} = Posts.update_post(post, %{body: "https://different.test/other"})
      Screenshots.reconcile(updated)

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.status == "pending"
      assert job.url == "https://different.test/other"
    end

    test "dropping the post's link removes the dismissed row and would-be files" do
      {post, ready} = ready_post(user())
      {:ok, _} = Screenshots.dismiss(ready)

      {:ok, updated} = Posts.update_post(post, %{body: "no more link at all"})
      Screenshots.reconcile(updated)

      refute Repo.get_by(PostScreenshot, post_id: post.id)
    end
  end

  describe "deliver_due/1 (draining the queue)" do
    test "is a no-op when :generate_screenshots is off (rows stay pending)" do
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)

      # config/test.exs sets :generate_screenshots false.
      Screenshots.deliver_due()

      assert Repo.get_by!(PostScreenshot, post_id: post.id).status == "pending"
    end

    test "a successful capture marks the job ready and broadcasts" do
      author = user()
      Vutuv.Activity.subscribe(author.id)
      post = url_post(author)
      {:ok, _job} = Screenshots.reconcile(post)

      Screenshots.deliver_due(force: true, capture: ok_capture())

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.status == "ready"
      assert job.screenshot == "0123456789ab.avif"
      assert job.captured_at

      assert_receive {:post_screenshot_ready, %{post_id: ready_id}}
      assert ready_id == post.id
    end

    test "a transient failure keeps the job pending with backoff" do
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)

      Screenshots.deliver_due(force: true, capture: fn _ -> {:error, :timeout} end)

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.status == "pending"
      assert job.attempts == 1
      assert job.next_attempt_at
      assert job.last_error =~ "timeout"
    end

    test "an internal-target (SSRF) refusal fails permanently at once" do
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)

      Screenshots.deliver_due(force: true, capture: fn _ -> {:error, :internal_target} end)

      assert Repo.get_by!(PostScreenshot, post_id: post.id).status == "failed"
    end

    test "a blocklisted-host refusal fails permanently (a stale row is never retried)" do
      # `qualify/1` keeps a blocklisted URL from ever enqueuing, but a row queued
      # before the host was blocklisted could still reach capture — it must die
      # at once, not burn five retries on a shot that can't work.
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)

      Screenshots.deliver_due(force: true, capture: fn _ -> {:error, :blocked_host} end)

      assert Repo.get_by!(PostScreenshot, post_id: post.id).status == "failed"
    end

    test "a non-200 link (redirect, 404) fails permanently at once (no retry)" do
      for reason <- [:redirect, {:bad_status, 404}] do
        post = url_post(user())
        {:ok, _job} = Screenshots.reconcile(post)

        Screenshots.deliver_due(force: true, capture: fn _ -> {:error, reason} end)

        job = Repo.get_by!(PostScreenshot, post_id: post.id)
        assert job.status == "failed", "expected #{inspect(reason)} to fail permanently"
        assert job.attempts == 1
      end
    end

    test "a 5xx / unreachable link stays pending with backoff (transient)" do
      for reason <- [{:server_error, 503}, :probe_failed] do
        post = url_post(user())
        {:ok, _job} = Screenshots.reconcile(post)

        Screenshots.deliver_due(force: true, capture: fn _ -> {:error, reason} end)

        job = Repo.get_by!(PostScreenshot, post_id: post.id)
        assert job.status == "pending", "expected #{inspect(reason)} to be retried"
        assert job.attempts == 1
        assert job.next_attempt_at
      end
    end

    test "a transient failure at the attempt cap becomes failed" do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      # One try below the cap, and due for retry now.
      Repo.update!(
        Ecto.Changeset.change(job,
          attempts: Screenshots.max_attempts() - 1,
          next_attempt_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
        )
      )

      Screenshots.deliver_due(force: true, capture: fn _ -> {:error, :timeout} end)

      assert Repo.get_by!(PostScreenshot, post_id: post.id).status == "failed"
    end
  end

  describe "requeue/1 (an admin hands a dead job back)" do
    test "a failed job returns to pending with a clean slate and is due at once" do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      failed =
        Repo.update!(
          Ecto.Changeset.change(job,
            status: "failed",
            attempts: Screenshots.max_attempts(),
            last_error: ":timeout",
            next_attempt_at: DateTime.utc_now(:second)
          )
        )

      assert {:ok, requeued} = Screenshots.requeue(failed)
      assert requeued.status == "pending"
      assert requeued.attempts == 0
      refute requeued.last_error
      refute requeued.next_attempt_at

      # Nothing else brings a `failed` row back: without this the job stays dead
      # even after the capture bug that killed it is fixed.
      assert Enum.map(Screenshots.list_due(), & &1.id) == [requeued.id]
    end

    test "an author-dismissed tombstone is never handed back" do
      {_post, ready} = ready_post(user())
      {:ok, dismissed} = Screenshots.dismiss(ready)

      assert {:error, :not_requeueable} = Screenshots.requeue(dismissed)
      assert Repo.get!(PostScreenshot, dismissed.id).status == "dismissed"
    end
  end

  describe "list_due/1" do
    test "excludes jobs whose backoff has not elapsed" do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      future = DateTime.add(DateTime.utc_now(:second), 3600, :second)
      Repo.update!(Ecto.Changeset.change(job, next_attempt_at: future))

      assert Screenshots.list_due() == []
    end
  end

  describe "resume_stuck/0" do
    test "re-queues a capturing job a crash orphaned, leaving fresh ones" do
      stuck = url_post(user())
      {:ok, stuck_job} = Screenshots.reconcile(stuck)

      old = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600, :second)

      Repo.update_all(
        from(ps in PostScreenshot, where: ps.id == ^stuck_job.id),
        set: [status: "capturing", updated_at: old]
      )

      fresh = url_post(user())
      {:ok, fresh_job} = Screenshots.reconcile(fresh)
      Repo.update!(Ecto.Changeset.change(fresh_job, status: "capturing"))

      assert Screenshots.resume_stuck() == 1
      assert Repo.get!(PostScreenshot, stuck_job.id).status == "pending"
      assert Repo.get!(PostScreenshot, fresh_job.id).status == "capturing"
    end
  end

  describe "create_post/2 integration" do
    setup do
      previous = Application.get_env(:vutuv, :generate_screenshots)
      Application.put_env(:vutuv, :generate_screenshots, true)
      on_exit(fn -> Application.put_env(:vutuv, :generate_screenshots, previous) end)
    end

    test "a qualifying new post enqueues a pending job" do
      post = create_post!(user(), %{body: "https://enqueued.test"})
      assert Repo.get_by!(PostScreenshot, post_id: post.id).status == "pending"
    end

    test "an image-less post with no URL enqueues nothing" do
      post = create_post!(user(), %{body: "just some words"})
      refute Repo.get_by(PostScreenshot, post_id: post.id)
    end
  end

  describe "cleanup" do
    test "deleting a post removes its screenshot row" do
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)

      {:ok, _} = Posts.delete_post(post)

      refute Repo.get_by(PostScreenshot, post_id: post.id)
    end
  end

  describe "deliver_due/1 with a YouTube link (thumbnail instead of Chromium)" do
    # These run the REAL capture path (no capture: stub): the YouTube fetch is
    # stubbed via :youtube_thumbnail_req_options, the page probe via
    # :post_screenshot_req_options, and stored files land in a tmp uploads dir.
    setup do
      tmp = Path.join(System.tmp_dir!(), "vutuv_yt_shots_#{System.unique_integer([:positive])}")
      previous = Application.get_env(:vutuv, :uploads_dir_prefix)
      Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

      on_exit(fn ->
        File.rm_rf(tmp)

        if previous,
          do: Application.put_env(:vutuv, :uploads_dir_prefix, previous),
          else: Application.delete_env(:vutuv, :uploads_dir_prefix)

        Application.delete_env(:vutuv, :youtube_thumbnail_req_options)
        Application.delete_env(:vutuv, :post_screenshot_req_options)
      end)

      # A real (tiny) JPEG: the store path opens it with libvips.
      fixture = Path.join(tmp, "fixture.jpg")
      File.mkdir_p!(tmp)
      {:ok, img} = Image.new(64, 36, color: [200, 30, 30])
      {:ok, _} = Image.write(img, fixture)
      jpeg_bytes = File.read!(fixture)

      {:ok, tmp: tmp, jpeg: jpeg_bytes}
    end

    defp stub_youtube(fun) when is_function(fun),
      do: Application.put_env(:vutuv, :youtube_thumbnail_req_options, plug: fun)

    defp youtube_post(author),
      do: create_post!(author, %{body: "https://www.youtube.com/watch?v=EZ05e7EMOLM"})

    test "stores the video's thumbnail raw — no page probe, no Chromium", %{
      tmp: tmp,
      jpeg: jpeg
    } do
      post = youtube_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      test_pid = self()
      maxres = "/vi/EZ05e7EMOLM/maxresdefault.jpg"

      stub_youtube(fn conn ->
        cond do
          conn.request_path == "/oembed" ->
            send(test_pid, :oembed_checked)

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, ~s({"title":"stub"}))

          conn.request_path == maxres ->
            conn
            |> Plug.Conn.put_resp_content_type("image/jpeg", nil)
            |> Plug.Conn.send_resp(200, jpeg)
        end
      end)

      # If the classic path ran anyway, this probe answer would mark the job
      # for retry (attempts 1), never ready — so "ready with 0 attempts"
      # proves the page was neither probed nor captured.
      stub_probe(500)

      Screenshots.deliver_due(force: true)

      job = Screenshots.get_job!(job.id)
      assert job.status == "ready"
      assert job.attempts == 0
      # The classic path stores .webp (framed capture); the thumbnail is .jpg.
      assert String.ends_with?(job.screenshot, ".jpg")
      assert_received :oembed_checked

      thumb_name = "thumb-#{Path.rootname(job.screenshot)}.avif"
      assert File.exists?(Path.join([tmp, "screenshots", job.id, thumb_name]))
    end

    test "falls back to the page capture when YouTube doesn't know the video" do
      post = youtube_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      stub_youtube(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(404, "Not Found")
      end)

      # The fallback probes the page; a 301 is a permanent refusal, so hitting
      # exactly that state proves the classic path took over.
      stub_probe(301)

      Screenshots.deliver_due(force: true)

      job = Screenshots.get_job!(job.id)
      assert job.status == "failed"
      assert job.last_error == ":redirect"
    end

    test "a non-YouTube link never calls the YouTube seam" do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      test_pid = self()

      stub_youtube(fn conn ->
        send(test_pid, :youtube_called)
        Plug.Conn.send_resp(conn, 500, "")
      end)

      stub_probe(301)

      Screenshots.deliver_due(force: true)

      assert Screenshots.get_job!(job.id).status == "failed"
      refute_received :youtube_called
    end
  end

  describe "requeue_youtube/0 (backfill after the thumbnail capture shipped)" do
    defp youtube_job(author, video_id, status) do
      post = create_post!(author, %{body: "https://youtu.be/#{video_id}"})
      {:ok, job} = Screenshots.reconcile(post)

      Repo.update!(
        Ecto.Changeset.change(job,
          status: status,
          attempts: Screenshots.max_attempts(),
          last_error: ":timeout"
        )
      )
    end

    test "re-queues finished YouTube jobs; other URLs and dismissed rows stay" do
      author = user()

      yt_ready = youtube_job(author, "AAAAAAAAAA1", "ready")
      yt_failed = youtube_job(author, "AAAAAAAAAA2", "failed")
      yt_dismissed = youtube_job(author, "AAAAAAAAAA3", "dismissed")
      {_post, other_ready} = ready_post(author)

      assert Screenshots.requeue_youtube() == 2

      requeued = Screenshots.get_job!(yt_ready.id)
      assert requeued.status == "pending"
      assert requeued.attempts == 0
      assert requeued.last_error == nil

      assert Screenshots.get_job!(yt_failed.id).status == "pending"
      assert Screenshots.get_job!(yt_dismissed.id).status == "dismissed"
      assert Screenshots.get_job!(other_ready.id).status == "ready"
    end
  end
end
