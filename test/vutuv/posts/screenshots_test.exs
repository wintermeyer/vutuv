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

  defp url_post(author, body \\ "Look at this: https://example.com/page"),
    do: create_post!(author, %{body: body})

  # A capture stub that "succeeds" with a fixed stored filename + size.
  defp ok_capture,
    do: fn _job -> {:ok, %{screenshot: "0123456789ab.avif", width: 400, height: 264}} end

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
end
