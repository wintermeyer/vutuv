defmodule VutuvWeb.VideoComposerTest do
  @moduledoc """
  The composer's video handling (issues #1907, #1909, #1910, #1911): the clip
  goes in through the real upload path, its tile follows the pipeline, the
  post waits for it, and the feed and the app bar show the wait.

  The clip is real (`Vutuv.VideoFixtures`) and the job runs the real ffmpeg
  where a test needs a ready clip; the progress messages are the ones the
  pipeline broadcasts, sent by hand where a test only needs the tile to move.
  """

  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Posts
  alias Vutuv.Posts.PendingVideoPost
  alias Vutuv.Posts.PostVideo
  alias Vutuv.Repo
  alias Vutuv.VideoFixtures
  alias Vutuv.Videos
  alias Vutuv.Videos.Job

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_video_ui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {conn, user} = create_and_login_user(conn)
    %{conn: conn, user: user}
  end

  defp open_composer(conn) do
    {:ok, live, _html} = live(conn, ~p"/feed")
    live |> element("#open-composer") |> render_click()
    live
  end

  defp upload_video!(live, user) do
    content = VideoFixtures.mp4_binary()
    name = "clip-#{System.unique_integer([:positive])}.mp4"

    input =
      file_input(live, "#composer-form", :video, [
        %{name: name, content: content, type: "video/mp4", size: byte_size(content)}
      ])

    render_upload(input, name)
    newest_video(user)
  end

  defp newest_video(user) do
    import Ecto.Query

    Repo.one!(
      from(v in PostVideo,
        where: v.user_id == ^user.id and is_nil(v.post_id),
        order_by: [desc: v.id],
        limit: 1
      )
    )
  end

  test "the picker offers one video, and the upload puts a tile with its stage in the composer",
       %{conn: conn, user: user} do
    live = open_composer(conn)
    assert has_element?(live, "#composer-add-video")

    video = upload_video!(live, user)
    assert video.stage == "queued"

    html = render(live)
    assert html =~ ~s(data-composer-video="#{video.id}")
    assert html =~ ~s(data-video-stage="queued")
    assert html =~ "Waiting in line"
    # One clip per post: the picker is gone, the remove control is there.
    refute has_element?(live, "#composer-add-video")
    assert has_element?(live, "[data-remove-video]")
    # The draft names it, so a reload brings it back.
    assert Posts.get_draft(user, nil).video_id == video.id
  end

  test "the tile follows the pipeline's progress without a reload", %{conn: conn, user: user} do
    live = open_composer(conn)
    video = upload_video!(live, user)

    Videos.update_state(video, stage: "transcoding", progress: 42)
    assert settled(live) =~ "Converting · 42 %"

    :ok = Job.run(video.id)
    html = settled(live)
    assert html =~ ~s(data-video-stage="ready")
    # The cover strip shows the stills, the cover marked.
    assert html =~ "data-video-frames"
    assert html =~ ~s(data-video-cover="true")
  end

  test "posting while the clip converts stores the post as waiting and shows the card and the chip",
       %{conn: conn, user: user} do
    live = open_composer(conn)
    video = upload_video!(live, user)

    live
    |> form("#composer-form", post: %{body: "Watch my talk", tags: ""})
    |> render_submit()

    assert [%PendingVideoPost{status: "waiting"} = pending] = Videos.pending_posts_for(user)
    assert pending.video_id == video.id
    assert pending.attrs["body"] == "Watch my talk"

    # The composer cleared, the waiting card is on the feed.
    html = render(live)
    assert html =~ ~s(data-pending-video-post="#{pending.id}")
    assert html =~ "Watch my talk"
    assert html =~ "Your post appears as soon as the video is ready"
    assert has_element?(live, "[data-cancel-pending-video]")
    refute html =~ ~s(data-composer-video="#{video.id}")

    # No post yet.
    assert Posts.get_post(user, pending.post_id || Ecto.UUID.generate()) == nil

    # The app bar's chip counts it.
    {:ok, shell, _} =
      live_isolated(build_conn(), VutuvWeb.ShellLive, session: shell_session(user))

    assert render(shell) =~ ~s(data-videos-in-progress="1")

    # The clip finishes: the post is published, the card goes, the chip goes.
    :ok = Job.run(video.id)
    published = Repo.get!(PendingVideoPost, pending.id)
    assert published.status == "published"
    post = Posts.get_post(published.post_id)
    assert post.body == "Watch my talk"
    assert post.video.id == video.id

    html = render(live)
    refute html =~ ~s(data-pending-video-post="#{pending.id}")
    assert html =~ ~s(data-post-video="#{video.id}")
    assert html =~ ~s(<video)
    assert html =~ PostVideo.url(video, "h264.mp4")

    refute render(shell) =~ "data-videos-in-progress"
  end

  test "a ready clip posts at once, with the player on the card", %{conn: conn, user: user} do
    live = open_composer(conn)
    video = upload_video!(live, user)
    :ok = Job.run(video.id)

    live
    |> form("#composer-form", post: %{body: "", tags: ""})
    |> render_submit()

    assert Videos.pending_posts_for(user) == []
    [post] = author_posts(user)
    assert post.video.id == video.id
    assert render(live) =~ ~s(data-post-video="#{video.id}")
  end

  test "the author picks the cover from the strip", %{conn: conn, user: user} do
    live = open_composer(conn)
    video = upload_video!(live, user)
    :ok = Job.run(video.id)
    video = Videos.get_video(video.id)

    case video.frames do
      [_only] ->
        # A three-second clip may yield a single still; nothing to pick then.
        :ok

      [_first, second | _] ->
        live |> element(~s([data-video-frame="#{second.position}"])) |> render_click()
        assert Videos.get_video(video.id).cover_frame_id == second.id
        assert render(live) =~ ~s(data-video-frame="#{second.position}" data-video-cover="true")
    end
  end

  test "removing the clip deletes it and brings the picker back", %{conn: conn, user: user} do
    live = open_composer(conn)
    video = upload_video!(live, user)

    live |> element("[data-remove-video]") |> render_click()
    assert Repo.get(PostVideo, video.id) == nil
    assert has_element?(live, "#composer-add-video")
    assert Posts.get_draft(user, nil) == nil
  end

  test "a refused clip blocks the post until it is removed, and the waiting card offers the way out",
       %{conn: conn, user: user} do
    # With the check on, the frames wait for a verdict instead of clearing on
    # the spot — which is what lets this test refuse one.
    put_config(:moderate_images, true)

    live = open_composer(conn)
    video = upload_video!(live, user)

    live
    |> form("#composer-form", post: %{body: "Text stays", tags: ""})
    |> render_submit()

    [pending] = Videos.pending_posts_for(user)
    # The check refuses it.
    Videos.frame_rejected(refused_frame!(video))

    html = render(live)
    assert html =~ ~s(data-pending-status="refused")
    assert html =~ "refused this video"
    assert has_element?(live, "[data-publish-without-video]")

    live |> element("[data-publish-without-video]") |> render_click()
    assert Repo.get!(PendingVideoPost, pending.id).status == "published"
    [post] = author_posts(user)
    assert post.body == "Text stays"
    assert post.video == nil
    refute render(live) =~ ~s(data-pending-video-post="#{pending.id}")
  end

  test "the waiting card can be cancelled", %{conn: conn, user: user} do
    live = open_composer(conn)
    video = upload_video!(live, user)

    live
    |> form("#composer-form", post: %{body: "Never mind", tags: ""})
    |> render_submit()

    [pending] = Videos.pending_posts_for(user)
    live |> element("[data-cancel-pending-video]") |> render_click()

    assert Repo.get!(PendingVideoPost, pending.id).status == "canceled"
    assert Repo.get(PostVideo, video.id) == nil
    refute render(live) =~ ~s(data-pending-video-post="#{pending.id}")
  end

  # The progress reaches the composer in two hops — the host's hook, then a
  # `send_update` to the component — so a render sent right behind the
  # broadcast would see the tile one step behind. One round trip lets the
  # second hop land first.
  defp settled(live) do
    _ = :sys.get_state(live.pid)
    render(live)
  end

  defp author_posts(user) do
    import Ecto.Query

    Repo.all(from(p in Vutuv.Posts.Post, where: p.user_id == ^user.id)) |> Repo.preload(:video)
  end

  # A frame row to refuse: the job's frames step is what mints them.
  defp refused_frame!(video) do
    :ok = Job.run(video.id)
    [frame | _] = Videos.get_video(video.id).frames
    frame.id
  end
end
