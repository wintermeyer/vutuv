defmodule VutuvWeb.ApiV2.VideosApiTest do
  @moduledoc """
  Video upload over `/api/2.0` (issue #1915): the same two steps the images
  take, on a longer clock — upload, poll until ready, attach.
  """

  use VutuvWeb.ConnCase, async: false

  alias Vutuv.ApiAuth
  alias Vutuv.Posts
  alias Vutuv.VideoFixtures
  alias Vutuv.Videos.Job

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()

    tmp = Path.join(System.tmp_dir!(), "vutuv_api_video_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:vutuv, :uploads_dir_prefix, prev),
        else: Application.delete_env(:vutuv, :uploads_dir_prefix)
    end)

    user = insert_activated_user()
    {:ok, token, _} = ApiAuth.create_pat(user, %{"name" => "t", "scopes" => ["posts:write"]})
    {:ok, conn: conn, user: user, token: token}
  end

  defp clip! do
    %Plug.Upload{path: VideoFixtures.mp4_path(), filename: "clip.mp4", content_type: "video/mp4"}
  end

  test "upload, poll until ready, attach to a post", %{conn: conn, token: token, user: user} do
    conn1 =
      conn
      |> authed(token)
      |> post("/api/2.0/me/post_videos", %{"video" => clip!(), "alt" => "A talk"})

    body = json_response(conn1, 202)

    assert %{
             "id" => video_id,
             "type" => "post_video",
             "alt" => "A talk",
             "ready" => false,
             "stage" => "queued",
             "duration_seconds" => 3
           } = body

    # Not ready: a post naming it is refused.
    conn2 =
      conn
      |> authed(token)
      |> post("/api/2.0/posts", %{"body" => "Too soon", "video_id" => video_id})

    assert conn2.status == 422

    :ok = Job.run(video_id)

    conn3 = conn |> authed(token) |> get("/api/2.0/me/post_videos/#{video_id}")
    assert %{"ready" => true, "stage" => "ready", "progress" => 100} = json_response(conn3, 200)

    conn4 =
      conn
      |> authed(token)
      |> post("/api/2.0/posts", %{"body" => "Watch", "video_id" => video_id})

    assert %{"id" => post_id, "video" => %{"url" => url, "duration_seconds" => 3}} =
             json_response(conn4, 201)

    assert url =~ "/post_videos/"
    assert Posts.get_post(post_id).video.id == video_id
    assert Posts.get_post(post_id).user_id == user.id

    # Attached now: the pending endpoints no longer know it.
    assert conn |> authed(token) |> get("/api/2.0/me/post_videos/#{video_id}") |> json_response(404)
  end

  test "an unposted upload can be deleted", %{conn: conn, token: token} do
    %{"id" => video_id} =
      conn
      |> authed(token)
      |> post("/api/2.0/me/post_videos", %{"video" => clip!()})
      |> json_response(202)

    conn2 = conn |> authed(token) |> delete("/api/2.0/me/post_videos/#{video_id}")
    assert conn2.status == 204
    assert conn |> authed(token) |> get("/api/2.0/me/post_videos/#{video_id}") |> json_response(404)
  end

  test "a file that is not a video is refused with a reason", %{conn: conn, token: token} do
    upload = %Plug.Upload{path: VideoFixtures.mp4_path(), filename: "clip.txt", content_type: "text/plain"}

    conn1 = conn |> authed(token) |> post("/api/2.0/me/post_videos", %{"video" => upload})
    assert conn1.status == 422
  end
end
