defmodule VutuvWeb.MastodonApi.MediaVideoTest do
  @moduledoc """
  Video upload through a Mastodon client (issue #1915): 202 while the clip is
  being converted and checked, 206 on the poll until it is, 422 for a status
  that names it too early, and the attachment described as a `video`.

  `async: false` because the module redirects `:uploads_dir_prefix` at the
  application level, which every uploader reads.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Posts
  alias Vutuv.VideoFixtures
  alias Vutuv.Videos.Job

  setup do
    Vutuv.RateLimiter.reset()

    tmp =
      Path.join(System.tmp_dir!(), "vutuv_mastodon_video_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    :ok
  end

  defp clip! do
    %Plug.Upload{path: VideoFixtures.mp4_path(), filename: "clip.mp4", content_type: "video/mp4"}
  end

  test "upload, poll, post: the two-step shape on a longer clock", %{conn: conn} do
    user = insert(:activated_user, admin?: true)
    token = mastodon_token(user, ["read", "write"])

    uploaded =
      conn
      |> mastodon_conn(token)
      |> post("/api/v2/media", %{"file" => clip!(), "description" => "Ein Vortrag"})
      |> json_response(202)

    assert uploaded["type"] == "video"
    assert uploaded["url"] == nil
    assert uploaded["description"] == "Ein Vortrag"
    assert uploaded["meta"]["original"]["duration"] == 3.0

    # v1 too: a clip is never ready synchronously.
    assert build_conn()
           |> mastodon_conn(token)
           |> post("/api/v1/media", %{"file" => clip!()})
           |> json_response(202)

    # Still converting: 206, and a status naming it is refused the Mastodon way.
    assert build_conn()
           |> mastodon_conn(token)
           |> get("/api/v1/media/#{uploaded["id"]}")
           |> json_response(206)

    refused =
      build_conn()
      |> mastodon_conn(token)
      |> post("/api/v1/statuses", %{"status" => "Zu früh", "media_ids" => [uploaded["id"]]})
      |> json_response(422)

    assert refused["error"] =~ "not finished processing"

    :ok = Job.run(uploaded["id"])

    ready =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v1/media/#{uploaded["id"]}")
      |> json_response(200)

    assert ready["type"] == "video"
    assert ready["url"] =~ "/post_videos/"
    assert ready["url"] =~ "h264.mp4"
    assert ready["preview_url"] =~ "cover.avif"

    status =
      build_conn()
      |> mastodon_conn(token)
      |> post("/api/v1/statuses", %{"status" => "Mit Video", "media_ids" => [uploaded["id"]]})
      |> json_response(200)

    assert [%{"type" => "video", "description" => "Ein Vortrag"} = attachment] =
             status["media_attachments"]

    assert attachment["url"] =~ "h264.mp4"
    assert Posts.get_post(status["id"]).video.id == uploaded["id"]
  end

  test "the instance announces the video limits once every member may upload", %{conn: conn} do
    VideoFixtures.put_video_config(:uploaders, :members)

    body = conn |> on_mastodon_host() |> get("/api/v2/instance") |> json_response(200)
    media = body["configuration"]["media_attachments"]

    assert media["video_size_limit"] == Vutuv.Videos.max_filesize()
    assert media["video_frame_rate_limit"] == 60
    assert "video/mp4" in media["supported_mime_types"]
  end

  test "while only admins upload, the instance says nothing about video", %{conn: conn} do
    body = conn |> on_mastodon_host() |> get("/api/v2/instance") |> json_response(200)
    media = body["configuration"]["media_attachments"]

    assert media["video_size_limit"] == 0
    refute "video/mp4" in media["supported_mime_types"]
  end

  test "a member who is not an admin gets the picture-only refusal for a clip", %{conn: conn} do
    user = insert(:activated_user)
    token = mastodon_token(user, ["read", "write"])

    body =
      conn
      |> mastodon_conn(token)
      |> post("/api/v2/media", %{"file" => clip!()})
      |> json_response(422)

    assert body["error"] =~ "an image"
    refute body["error"] =~ "video"
  end

  test "an unposted clip can be deleted", %{conn: conn} do
    user = insert(:activated_user, admin?: true)
    token = mastodon_token(user, ["read", "write"])

    uploaded =
      conn
      |> mastodon_conn(token)
      |> post("/api/v2/media", %{"file" => clip!()})
      |> json_response(202)

    assert build_conn()
           |> mastodon_conn(token)
           |> delete("/api/v1/media/#{uploaded["id"]}")
           |> json_response(200)

    assert build_conn()
           |> mastodon_conn(token)
           |> get("/api/v1/media/#{uploaded["id"]}")
           |> json_response(404)
  end
end
