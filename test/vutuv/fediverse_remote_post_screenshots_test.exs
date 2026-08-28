defmodule Vutuv.FediverseRemotePostScreenshotsTest do
  @moduledoc """
  Link screenshots for cached fediverse posts — the remote twin of
  `Vutuv.Posts.ScreenshotsTest`: a followed account's single-URL, picture-less,
  unwarned post rides the same `post_screenshots` queue a member post uses
  (one shared worker, capture, YouTube branch and AI gate; only the enqueue
  trigger and the ready-announcement differ).

  `async: false` — `record_remote_post/2` touches the shared `Vutuv.RateLimiter`
  ETS table, and several tests flip the global `:moderate_images` /
  `:uploads_dir_prefix` env.
  """
  use Vutuv.DataCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots

  @actor "https://pics.example/users/shooter"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @followers @actor <> "/followers"
  @url "https://blog.example/entry"
  @picture "https://pics.example/media/1.jpg"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp account do
    Repo.insert!(%RemoteAccount{
      actor_uri: @actor,
      host: "pics.example",
      handle: "shooter",
      name: "Shooter",
      inbox_uri: "https://pics.example/users/shooter/inbox"
    })
  end

  defp member, do: insert(:activated_user, fediverse_followers?: true)

  defp follow(user, account) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      muted: false,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
    })
  end

  defp create_activity(overrides \\ %{}) do
    object =
      Map.merge(
        %{
          "id" => "https://pics.example/posts/1",
          "type" => "Note",
          "attributedTo" => @actor,
          "content" => "<p>Read #{@url} now</p>",
          "url" => "https://pics.example/@shooter/1",
          "published" => "2026-07-20T09:00:00Z",
          "to" => [@public],
          "cc" => [@followers]
        },
        Map.get(overrides, :object, %{})
      )

    Map.merge(
      %{"type" => "Create", "actor" => @actor, "object" => object},
      Map.drop(overrides, [:object])
    )
  end

  defp update_activity(object_overrides) do
    %{
      "type" => "Update",
      "actor" => @actor,
      "object" =>
        Map.merge(
          %{
            "id" => "https://pics.example/posts/1",
            "type" => "Note",
            "content" => "<p>Read #{@url} now</p>",
            "to" => [@public],
            "cc" => [@followers]
          },
          object_overrides
        )
    }
  end

  # A followed account whose single-URL post has just arrived; returns the row.
  defp recorded_post(overrides \\ %{}) do
    follow(member(), account())
    assert :ok = Fediverse.record_remote_post(create_activity(overrides), @actor)
    Repo.get_by!(RemotePost, remote_account_id: Repo.get_by!(RemoteAccount, actor_uri: @actor).id)
  end

  defp job_of(%RemotePost{id: id}), do: Repo.get_by(PostScreenshot, remote_post_id: id)

  # The captured-and-released state, as `ready_post/1` in the member twin.
  defp make_ready(%PostScreenshot{} = job, moderation \\ "approved") do
    {:ok, ready} =
      job
      |> Ecto.Changeset.change(
        status: "ready",
        screenshot: "0123456789ab.avif",
        moderation: moderation
      )
      |> Repo.update()

    # The row and the disk have to agree: since issue #1443 a row naming a file
    # that is not there renders the placeholder, not a URL that would 404.
    dir = Path.join(Vutuv.Uploads.uploads_dir_prefix(), "screenshots/#{ready.id}")
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(20, 20, color: [1, 2, 3])
    {:ok, _} = Image.write(img, Path.join(dir, "thumb-0123456789ab.avif"))
    on_exit(fn -> File.rm_rf(dir) end)

    ready
  end

  defp ok_capture,
    do: fn _job -> {:ok, %{screenshot: "0123456789ab.avif", width: 400, height: 264}} end

  describe "record_remote_post/2 (enqueue on arrival)" do
    test "a single-URL, picture-less post enqueues a pending capture job" do
      post = recorded_post()

      job = job_of(post)
      assert job.status == "pending"
      assert job.url == @url
      assert is_nil(job.post_id)
    end

    test "the URL survives the HTML link markup Mastodon really sends" do
      content =
        ~s(<p>Read <a href="#{@url}"><span class="invisible">https://</span>) <>
          ~s(<span class="ellipsis">blog.example/en</span><span class="invisible">try</span></a></p>)

      post = recorded_post(%{object: %{"content" => content}})

      assert job_of(post).url == @url
    end

    test "a post with a picture attachment gets no job" do
      attachment = %{"type" => "Document", "mediaType" => "image/jpeg", "url" => @picture}
      post = recorded_post(%{object: %{"attachment" => [attachment]}})

      assert is_nil(job_of(post))
    end

    test "a content warning or the sensitive flag gets no job" do
      warned = recorded_post(%{object: %{"summary" => "CW: politics"}})
      assert is_nil(job_of(warned))

      sensitive_activity =
        create_activity(%{object: %{"sensitive" => true, "id" => "https://pics.example/posts/2"}})

      assert :ok = Fediverse.record_remote_post(sensitive_activity, @actor)
      sensitive = Repo.get_by!(RemotePost, object_uri: "https://pics.example/posts/2")
      assert is_nil(job_of(sensitive))
    end

    test "two distinct URLs get no job" do
      content = "<p>Read #{@url} and https://other.example/page</p>"
      post = recorded_post(%{object: %{"content" => content}})

      assert is_nil(job_of(post))
    end

    test "a redelivery keeps the one existing job" do
      post = recorded_post()
      job = job_of(post)

      assert :skip = Fediverse.record_remote_post(create_activity(), @actor)

      assert Repo.aggregate(PostScreenshot, :count) == 1
      assert job_of(post).id == job.id
    end
  end

  describe "update_remote_post/2 (reconcile on edit)" do
    test "an edit that changes the single URL resets the job to the new one" do
      post = recorded_post()
      make_ready(job_of(post))

      edit = update_activity(%{"content" => "<p>Moved: https://blog.example/moved</p>"})
      assert :ok = Fediverse.update_remote_post(edit, @actor)

      job = job_of(post)
      assert job.status == "pending"
      assert job.url == "https://blog.example/moved"
    end

    test "an edit that adds a content warning cancels the job" do
      post = recorded_post()
      assert job_of(post)

      edit = update_activity(%{"summary" => "CW now"})
      assert :ok = Fediverse.update_remote_post(edit, @actor)

      assert is_nil(job_of(post))
    end

    test "an edit that adds a picture cancels the job" do
      post = recorded_post()
      assert job_of(post)

      attachment = %{"type" => "Document", "mediaType" => "image/jpeg", "url" => @picture}
      edit = update_activity(%{"attachment" => [attachment]})
      assert :ok = Fediverse.update_remote_post(edit, @actor)

      assert is_nil(job_of(post))
    end

    test "an edit that brings the first URL enqueues a job" do
      post = recorded_post(%{object: %{"content" => "<p>No link yet.</p>"}})
      assert is_nil(job_of(post))

      edit = update_activity(%{"content" => "<p>Now: #{@url}</p>"})
      assert :ok = Fediverse.update_remote_post(edit, @actor)

      assert job_of(post).url == @url
    end
  end

  describe "deletion cleans the files" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "vutuv_rps_#{System.unique_integer([:positive])}")
      previous = Application.get_env(:vutuv, :uploads_dir_prefix)
      Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

      on_exit(fn ->
        File.rm_rf(tmp)

        if previous,
          do: Application.put_env(:vutuv, :uploads_dir_prefix, previous),
          else: Application.delete_env(:vutuv, :uploads_dir_prefix)
      end)

      {:ok, tmp: tmp}
    end

    defp stored_files(job) do
      dir = Vutuv.Uploads.disk_dir("screenshots/#{job.id}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "thumb-0123456789ab.avif"), "avif")
      dir
    end

    test "an upstream Delete removes the row and the stored files" do
      post = recorded_post()
      dir = stored_files(make_ready(job_of(post)))

      assert :ok = Fediverse.delete_remote_post(@actor, post.object_uri)

      refute Repo.get(RemotePost, post.id)
      assert Repo.aggregate(PostScreenshot, :count) == 0
      refute File.exists?(dir)
    end

    test "the retention sweep removes the files too" do
      post = recorded_post()
      dir = stored_files(make_ready(job_of(post)))

      future = DateTime.add(DateTime.utc_now(:second), 200 * 86_400, :second)
      assert Fediverse.expire_due_remote_posts(future) == 1

      refute Repo.get(RemotePost, post.id)
      assert Repo.aggregate(PostScreenshot, :count) == 0
      refute File.exists?(dir)
    end
  end

  describe "deliver_due/1 (the shared queue drains remote jobs)" do
    test "a successful capture marks the remote-owned job ready" do
      post = recorded_post()

      Screenshots.deliver_due(force: true, capture: ok_capture())

      job = job_of(post)
      assert job.status == "ready"
      assert job.screenshot == "0123456789ab.avif"
      # :moderate_images is off in tests, so the capture releases immediately.
      assert PostScreenshot.ready?(job)
    end

    test "with the AI gate on, the scan is enqueued with no owning member" do
      Application.put_env(:vutuv, :moderate_images, true)
      on_exit(fn -> Application.put_env(:vutuv, :moderate_images, false) end)

      post = recorded_post()
      Screenshots.deliver_due(force: true, capture: ok_capture())

      job = job_of(post)
      assert job.moderation == "pending"
      refute PostScreenshot.ready?(job)

      scan = Repo.get_by!(ImageScan, kind: "post_screenshot", subject_id: job.id)
      assert is_nil(scan.owner_user_id)
      assert scan.fingerprint == job.screenshot
    end
  end

  describe "moderation verdicts on a remote-owned row" do
    test "an approval releases the screenshot (and needs no member post)" do
      post = recorded_post()
      job = make_ready(job_of(post), "pending")

      scan = %ImageScan{
        kind: "post_screenshot",
        subject_id: job.id,
        fingerprint: job.screenshot
      }

      assert :ok = ImageSubjects.apply_approved(scan)
      assert PostScreenshot.ready?(job_of(post))
    end

    test "a rejection clears the capture" do
      post = recorded_post()
      job = make_ready(job_of(post), "pending")

      scan = %ImageScan{
        kind: "post_screenshot",
        subject_id: job.id,
        fingerprint: job.screenshot
      }

      assert :ok = ImageSubjects.apply_rejected(scan)

      job = job_of(post)
      assert job.status == "failed"
      assert job.moderation == "rejected"
      assert is_nil(job.screenshot)
    end

    test "a stranded pending row is found for re-enqueue, owner-less" do
      post = recorded_post()
      job = make_ready(job_of(post), "pending")

      assert {"post_screenshot", job.id, nil, job.screenshot} in ImageSubjects.stranded_pending()
    end
  end

  describe "rendering" do
    defp card(post) do
      render_component(&VutuvWeb.PostComponents.remote_post_card/1,
        remote_post: Repo.preload(post, [:remote_account, :screenshot], force: true),
        viewer: nil,
        images: []
      )
    end

    test "a released screenshot renders on the card" do
      post = recorded_post()
      make_ready(job_of(post))

      html = card(post)
      assert html =~ "data-link-screenshot"
      assert html =~ "/screenshots/#{job_of(post).id}/thumb-0123456789ab.avif"
    end

    test "on a timeline the shot sits INSIDE the clamped body, ahead of the text" do
      post = recorded_post()
      make_ready(job_of(post))

      html = card(post)

      # Two float rules meet here. A float only wraps what FOLLOWS it, so the
      # shot has to come before the prose; and a float left outside a
      # height-clamped `flow-root` box is not wrapped by it at all, it merely
      # narrows the whole box — so it has to be the clamp block's first child.
      # `post-clamp--wrap` is the body saying it switched to the height clamp a
      # float needs (`-webkit-line-clamp` cannot wrap around one).
      assert [_before, clamped] = String.split(html, "post-clamp--wrap", parts: 2)
      assert clamped =~ ~r/data-link-screenshot.*Read/s
    end

    test "an unreleased or missing capture renders nothing" do
      post = recorded_post()
      refute card(post) =~ "data-link-screenshot"

      make_ready(job_of(post), "pending")
      refute card(post) =~ "data-link-screenshot"
    end

    test "the feed source preloads the screenshot" do
      user = member()
      acc = account()
      follow(user, acc)
      assert :ok = Fediverse.record_remote_post(create_activity(), @actor)

      assert [entry] = Fediverse.feed_remote_posts(user, 10, nil)
      assert %PostScreenshot{} = entry.remote_post.screenshot
    end
  end
end
