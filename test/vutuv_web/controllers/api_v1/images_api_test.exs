defmodule VutuvWeb.ApiV1.ImagesApiTest do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()

    tmp = Path.join(System.tmp_dir!(), "vutuv_api_img_#{System.unique_integer([:positive])}")
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

    {:ok, conn: conn, user: user, token: token, tmp: tmp}
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp jpeg!(tmp) do
    src = Path.join(tmp, "src-#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(64, 64, color: [10, 200, 100])
    {:ok, _} = Image.write(img, src)
    %Plug.Upload{path: src, filename: "photo.jpg", content_type: "image/jpeg"}
  end

  test "upload, attach to a post, and the audience proxy applies", %{
    conn: conn,
    token: token,
    tmp: tmp
  } do
    conn1 =
      conn
      |> authed(token)
      |> post("/api/v1/me/post_images", %{"image" => jpeg!(tmp), "alt" => "Greenfield"})

    body = json_response(conn1, 201)
    assert %{"id" => image_id, "alt" => "Greenfield", "content_type" => "image/jpeg"} = body

    conn2 =
      build_conn()
      |> authed(token)
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/posts", Jason.encode!(%{body: "With image", image_ids: [image_id]}))

    post_body = json_response(conn2, 201)
    assert [%{"alt" => "Greenfield"}] = post_body["images"]
  end

  test "garbage uploads are a 422, missing field a 400", %{conn: conn, token: token, tmp: tmp} do
    src = Path.join(tmp, "not_an_image.txt")
    File.write!(src, "plain text")

    conn1 =
      conn
      |> authed(token)
      |> post("/api/v1/me/post_images", %{
        "image" => %Plug.Upload{path: src, filename: "x.txt", content_type: "text/plain"}
      })

    assert conn1.status == 422

    conn2 = build_conn() |> authed(token) |> post("/api/v1/me/post_images", %{})
    assert conn2.status == 400
  end

  test "deleting a pending image; attached ones refuse", %{
    conn: conn,
    user: user,
    token: token,
    tmp: tmp
  } do
    conn1 = conn |> authed(token) |> post("/api/v1/me/post_images", %{"image" => jpeg!(tmp)})
    %{"id" => image_id} = json_response(conn1, 201)

    conn2 = build_conn() |> authed(token) |> delete("/api/v1/me/post_images/#{image_id}")
    assert conn2.status == 204
    assert Repo.get(PostImage, image_id) == nil

    {:ok, attached} = Posts.create_pending_image(user, jpeg!(tmp).path, "photo.jpg")
    {:ok, _post} = Posts.create_post(user, %{"body" => "img", "image_ids" => [attached.id]})

    conn3 = build_conn() |> authed(token) |> delete("/api/v1/me/post_images/#{attached.id}")
    assert conn3.status == 404
    assert Repo.get(PostImage, attached.id)
  end

  test "posts:read cannot upload", %{conn: conn, user: user, tmp: tmp} do
    {:ok, read_token, _} = ApiAuth.create_pat(user, %{"name" => "r", "scopes" => ["posts:read"]})

    conn = conn |> authed(read_token) |> post("/api/v1/me/post_images", %{"image" => jpeg!(tmp)})
    assert conn.status == 403
  end
end
