defmodule VutuvWeb.PostVideoControllerTest do
  @moduledoc """
  The video proxy (issue #1912): who may fetch a clip's files, and the byte
  ranges a `<video>` element asks for — Safari refuses to play from a server
  that answers a range request with the whole file.
  """

  use VutuvWeb.ConnCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Posts
  alias Vutuv.Posts.PostVideo
  alias Vutuv.PostVideoStore
  alias Vutuv.VideoFixtures
  alias Vutuv.Videos
  alias Vutuv.Videos.Job
  alias VutuvWeb.RemoteMediaToken

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_video_proxy_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {author_conn, author} = create_and_login_user(conn)
    path = VideoFixtures.mp4_path()
    {:ok, video} = Videos.create_pending_video(author, path, Path.basename(path))
    :ok = Job.run(video.id)
    %{author: author, author_conn: author_conn, video: Videos.get_video(video.id)}
  end

  defp publish!(author, video, attrs \\ %{}) do
    {:ok, post} = Posts.create_post(author, Map.merge(%{body: "Clip", video_id: video.id}, attrs))
    post
  end

  defp stranger_conn do
    {conn, _stranger} =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> create_and_login_user(registration_attrs("stranger"))

    conn
  end

  test "a public post's clip is served to anybody, whole, with the video type",
       %{author: author, video: video} do
    publish!(author, video)

    conn = get(build_conn(), PostVideo.url(video, "h264.mp4"))
    assert conn.status == 200
    assert hd(get_resp_header(conn, "content-type")) =~ "video/mp4"
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert hd(get_resp_header(conn, "cache-control")) =~ "immutable"

    assert byte_size(conn.resp_body) ==
             File.stat!(PostVideoStore.rendition_path(video.token, "h264")).size
  end

  test "a range request is answered with 206 and exactly the bytes asked for",
       %{author: author, video: video} do
    publish!(author, video)
    url = PostVideo.url(video, "h264.mp4")
    file = PostVideoStore.rendition_path(video.token, "h264")
    size = File.stat!(file).size
    <<head::binary-size(2), _::binary>> = File.read!(file)

    conn = build_conn() |> put_req_header("range", "bytes=0-1") |> get(url)
    assert conn.status == 206
    assert get_resp_header(conn, "content-range") == ["bytes 0-1/#{size}"]
    assert conn.resp_body == head

    conn = build_conn() |> put_req_header("range", "bytes=#{size - 10}-") |> get(url)
    assert conn.status == 206
    assert byte_size(conn.resp_body) == 10
    assert get_resp_header(conn, "content-range") == ["bytes #{size - 10}-#{size - 1}/#{size}"]

    conn = build_conn() |> put_req_header("range", "bytes=-5") |> get(url)
    assert conn.status == 206
    assert byte_size(conn.resp_body) == 5

    conn = build_conn() |> put_req_header("range", "bytes=#{size + 5}-") |> get(url)
    assert conn.status == 416
    assert get_resp_header(conn, "content-range") == ["bytes */#{size}"]
  end

  test "the cover, its data-saving twin and the JPEG for scrapers resolve; nothing else does",
       %{author: author, video: video} do
    publish!(author, video)

    cover = get(build_conn(), PostVideo.cover_url(video))
    assert cover.status == 200
    assert hd(get_resp_header(cover, "content-type")) =~ "image/avif"
    assert get(build_conn(), PostVideo.url(video, "cover-lite.avif")).status == 200

    og = get(build_conn(), PostVideo.og_url(video))
    assert og.status == 200
    assert hd(get_resp_header(og, "content-type")) =~ "image/jpeg"

    assert get(build_conn(), PostVideo.url(video, "original.mp4")).status == 404
    assert get(build_conn(), PostVideo.url(video, "..%2Foriginal.mp4")).status == 404
    assert get(build_conn(), "/post_videos/nope/h264.mp4").status == 404
  end

  test "an unattached clip is its uploader's alone, stills included",
       %{author_conn: author_conn, video: video} do
    [frame | _] = video.frames

    assert get(build_conn(), PostVideo.url(video, "h264.mp4")).status == 404
    assert get(build_conn(), PostVideo.frame_url(video, frame)).status == 404
    assert get(stranger_conn(), PostVideo.url(video, "h264.mp4")).status == 404

    assert get(author_conn, PostVideo.url(video, "h264.mp4")).status == 200
    still = get(author_conn, PostVideo.frame_url(video, frame))
    assert still.status == 200
    assert hd(get_resp_header(still, "content-type")) =~ "image/jpeg"
    assert get_resp_header(still, "cache-control") == ["private, no-store"]
  end

  test "a restricted post's clip follows the post's audience, session or capability",
       %{author: author, author_conn: author_conn, video: video} do
    publish!(author, video, %{denials: [%{"wildcard" => "everyone"}]})
    url = PostVideo.url(video, "h264.mp4")

    assert get(build_conn(), url).status == 404
    assert get(stranger_conn(), url).status == 404
    assert get(author_conn, url).status == 200

    # The capability names the author, and opens the renditions and nothing else.
    query = RemoteMediaToken.post_video_query(video.token, author.id)
    assert get(build_conn(), url <> "?" <> query).status == 200
    assert get(build_conn(), PostVideo.og_url(video) <> "&" <> query).status == 404

    stranger = insert_activated_user()
    stranger_query = RemoteMediaToken.post_video_query(video.token, stranger.id)
    assert get(build_conn(), url <> "?" <> stranger_query).status == 404
  end
end
