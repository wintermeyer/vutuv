defmodule VutuvWeb.MastodonApi.ClientCompatibilityTest do
  @moduledoc """
  What a Mastodon client believes about this server before it does anything, and
  what it gets for a resource we do not have.

  These are not endpoint features. They are the answers a client reads to decide
  whether to open a stream, what to convert a photo into, and whether the server
  is working at all — and each one used to say something untrue, which a client
  has no way to see past. An Ivory user reported the three symptoms together
  (home timeline spinning, photo upload refused, page logo missing) and they all
  live here.
  """
  use VutuvWeb.ConnCase

  import Vutuv.MastodonHelpers

  alias Vutuv.PostImageStore
  alias Vutuv.Posts

  describe "the instance document says what this installation can really do" do
    setup %{conn: conn} do
      {:ok, instance: conn |> on_mastodon_host() |> get("/api/v2/instance") |> json_response(200)}
    end

    test "names the streaming endpoint instead of nil", %{instance: instance} do
      # A client that reads no streaming URL opens no stream, so the home
      # timeline never learns about anything after the page it fetched.
      assert instance["configuration"]["urls"]["streaming"] ==
               "ws://mastodon.localhost:4001/api/v1/streaming"
    end

    test "the v1 document names it too", %{conn: conn} do
      v1 = conn |> on_mastodon_host() |> get("/api/v1/instance") |> json_response(200)

      assert v1["urls"]["streaming_api"] == "ws://mastodon.localhost:4001/api/v1/streaming"
    end

    test "admits that a post takes pictures", %{instance: instance} do
      # `0` told every client this server accepts no attachments at all.
      assert instance["configuration"]["statuses"]["max_media_attachments"] ==
               Posts.max_images_per_post()

      assert Posts.max_images_per_post() > 0
    end

    test "lists the image types the uploader really accepts", %{instance: instance} do
      # The empty list is what left a phone client with nothing to convert the
      # photo library's HEIC *into*, so it sent the original and got a 422.
      media = instance["configuration"]["media_attachments"]

      assert media["supported_mime_types"] != []
      assert "image/jpeg" in media["supported_mime_types"]

      # Derived, so an installation whose libvips decodes HEIC advertises it —
      # and the clip containers follow only where ffmpeg is there (issue #1915).
      images =
        PostImageStore.extension_whitelist()
        |> Enum.map(&MIME.from_path("x" <> &1))
        |> Enum.uniq()

      videos = if Vutuv.Videos.enabled?(), do: Vutuv.Videos.mime_types(), else: []

      assert media["supported_mime_types"] == images ++ videos
      assert media["image_size_limit"] == Posts.max_image_filesize()
      assert media["image_matrix_limit"] > 0
    end
  end

  describe "a path this adapter does not implement" do
    setup do
      {:ok, token: mastodon_token(insert(:activated_user), ["read", "write"])}
    end

    test "answers JSON on the main host, not the website's HTML error page", %{
      conn: conn,
      token: token
    } do
      # The main host is the one a member types into a phone app, so this is the
      # host every client actually uses. An unrouted /api/v1/… fell through to
      # the website and handed the client markup where it expected an object.
      conn =
        conn
        |> Map.put(:host, "localhost")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> post("/api/v1/scheduled_statuses", %{})

      assert json_response(conn, 404) == %{"error" => "Record not found"}
    end

    test "and on the API subdomain", %{conn: conn, token: token} do
      conn = conn |> mastodon_conn(token) |> get("/api/v1/scheduled_statuses")

      assert json_response(conn, 404) == %{"error" => "Record not found"}
    end

    test "the root of the API host sends a person to the site", %{conn: conn} do
      # Everything else on that origin answers JSON, which is right for a client
      # and a dead end for somebody who typed the technical name by hand.
      conn = conn |> on_mastodon_host() |> get("/")

      assert redirected_to(conn) == "http://localhost:4001/"
    end

    test "leaves the website alone", %{conn: conn} do
      # The catch-all names Mastodon's two version prefixes only, so a site path
      # still gets the site's own answer and not this JSON error.
      conn = conn |> Map.put(:host, "localhost") |> get("/no-such-member-here")

      assert html_response(conn, 404)
    end
  end

  describe "Local and Federated are different lists" do
    setup do
      author = insert(:activated_user)
      post = insert(:post, user: author)
      viewer = insert(:activated_user)

      {:ok, token: mastodon_token(viewer, ["read"]), post: post}
    end

    test "local=true is this site's own posts", %{conn: conn, token: token, post: post} do
      ids =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/timelines/public", %{"local" => "true"})
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert post.id in ids
    end

    test "remote=true excludes them", %{conn: conn, token: token, post: post} do
      # Both flags used to be ignored, so a client's two tabs asked different
      # questions and got one answer — the same list under two names.
      ids =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/timelines/public", %{"remote" => "true"})
        |> json_response(200)
        |> Enum.map(& &1["id"])

      refute post.id in ids
    end

    test "no flag is both, so the site's own posts are still there", %{
      conn: conn,
      token: token,
      post: post
    } do
      ids =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/timelines/public")
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert post.id in ids
    end
  end

  describe "an organization account" do
    test "carries its own logo and cover, not the installation's icon", %{conn: conn} do
      member = insert(:activated_user)

      organization =
        insert(:organization, logo: "orglogotoken", cover: "orgcovertoken")
        |> allow_mastodon_clients()

      token = mastodon_token(member, ["read"])

      account =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/accounts/#{organization.id}")
        |> json_response(200)

      assert account["group"] == true
      assert account["avatar"] =~ "/organization_images/orglogotoken/"
      assert account["avatar_static"] == account["avatar"]
      assert account["header"] =~ "/organization_images/orgcovertoken/"
      refute account["avatar"] =~ "icon-512"
    end

    test "a page with no picture keeps the stand-in", %{conn: conn} do
      member = insert(:activated_user)
      organization = insert(:organization) |> allow_mastodon_clients()
      token = mastodon_token(member, ["read"])

      account =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/accounts/#{organization.id}")
        |> json_response(200)

      assert account["avatar"] =~ "icon-512"
    end
  end

  describe "the media endpoint's refusal" do
    test "names what this installation accepts rather than a fixed list", %{conn: conn} do
      token = mastodon_token(insert(:activated_user), ["write"])

      upload = %Plug.Upload{
        path: Path.join(System.tmp_dir!(), "not-an-image.txt"),
        filename: "photo.heic",
        content_type: "image/heic"
      }

      File.write!(upload.path, "not an image")
      on_exit(fn -> File.rm(upload.path) end)

      body =
        conn
        |> mastodon_conn(token)
        |> post("/api/v1/media", %{"file" => upload})
        |> json_response(422)

      # Whatever the whitelist holds, the sentence has to hold the same thing —
      # this is the message a member reads after the upload already went up.
      for extension <- PostImageStore.extension_whitelist() do
        assert body["error"] =~ String.upcase(String.trim_leading(extension, "."))
      end
    end
  end

  describe "the streaming socket" do
    test "answers at Mastodon's documented path, not Phoenix's suffixed one" do
      # Every client dials wss://<host>/api/v1/streaming — that exact path.
      # Phoenix's default appends the transport name, so the documented address
      # 404ed and the stream was unreachable although every part of it worked.
      {path, _module, opts} =
        VutuvWeb.Endpoint.__sockets__()
        |> Enum.find(fn {path, _module, _opts} -> path == "/api/v1/streaming" end)

      assert path == "/api/v1/streaming"
      assert opts[:websocket][:path] == "/"
    end
  end
end
