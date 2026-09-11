defmodule VutuvWeb.ImageProxyCacheTest do
  @moduledoc """
  What a browser is allowed to remember about a picture it was once shown
  (issue #2170).

  `VutuvWeb.ImageProxy` authorizes **per viewer** and then answered
  `max-age=31536000, immutable`, which tells the browser not even to ask again
  for a year. So a post switched to restricted went on feeding its pictures out
  of every browser that had already seen them, and a Media Kit picture taken
  down for copyright never disappeared from one either — the print-quality
  original included.

  Three claims here, one per tier:

    * a **derived version** (a size of a picture, the thing a page renders) is
      revalidatable: a short window, and an `ETag` so the check costs a 304
      rather than the bytes;
    * a **revoked** reader gets the 404 even when they arrive holding the
      matching `ETag` — the conditional request is answered behind the same
      authorization as the full one, never in front of it;
    * a **file hand-over** (the full-resolution original a Media Kit exists to
      give away) is not stored at all.

  Not async: it flips `:uploads_dir_prefix` and `:moderate_images`, which are
  global and outside the SQL sandbox.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Images
  alias Vutuv.Posts
  alias Vutuv.Posts.PostDenial
  alias Vutuv.PressKit
  alias Vutuv.Repo

  @derived "private, max-age=300, must-revalidate"
  @no_store "private, no-store"

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_proxy_cache_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    put_config(:moderate_images, false)
    on_exit(fn -> File.rm_rf(tmp) end)

    {owner_conn, owner} = create_and_login_user(conn)
    {:ok, tmp: tmp, owner: owner, owner_conn: owner_conn}
  end

  defp anonymous, do: Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})

  defp cache_control(conn), do: conn |> get_resp_header("cache-control") |> List.first()
  defp etag(conn), do: conn |> get_resp_header("etag") |> List.first()

  defp photo_file!(tmp) do
    src = Path.join(tmp, "shot-#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(120, 90, color: [10, 120, 200])
    {:ok, _} = Image.write(img, src)
    src
  end

  defp post_photo!(author, tmp, image_attrs \\ %{}) do
    {:ok, image} = Posts.create_pending_image(author, photo_file!(tmp), "photo.jpg")
    {:ok, image} = Posts.update_image_settings(image, image_attrs)
    {:ok, post} = Posts.create_post(author, %{body: "pic", image_ids: [image.id]})
    {post, image}
  end

  defp press_photo!(owner, tmp) do
    path = Path.join(tmp, "press-#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(600, 400, color: [10, 120, 200])
    {:ok, _} = Image.write(img, path)

    {:ok, image} =
      PressKit.create(owner, owner, {path, "press.jpg"}, %{
        "rights_confirmed" => "true",
        "credit" => "Foto: Ada King"
      })

    Repo.update!(Ecto.Changeset.change(image, moderation: "approved"))
  end

  describe "a derived version" do
    test "on a public post is revalidatable, not immutable", %{owner: owner, tmp: tmp} do
      {_post, image} = post_photo!(owner, tmp)

      conn = get(anonymous(), "/post_images/#{image.token}/feed.avif")

      assert conn.status == 200
      assert cache_control(conn) == @derived
      refute cache_control(conn) =~ "immutable"
      assert etag(conn)
    end

    test "on a restricted post gets the same window as a public one", %{
      owner: owner,
      owner_conn: owner_conn,
      tmp: tmp
    } do
      {post, image} = post_photo!(owner, tmp)
      Repo.insert!(%PostDenial{post_id: post.id, wildcard: "everyone"})

      conn = get(owner_conn, "/post_images/#{image.token}/feed.avif")

      assert conn.status == 200
      assert cache_control(conn) == @derived
      assert get(anonymous(), "/post_images/#{image.token}/feed.avif").status == 404
    end

    test "still in the composer, with no post yet, gets it too", %{
      owner: owner,
      owner_conn: owner_conn,
      tmp: tmp
    } do
      {:ok, image} = Posts.create_pending_image(owner, photo_file!(tmp), "photo.jpg")

      conn = get(owner_conn, "/post_images/#{image.token}/feed.avif")

      assert conn.status == 200
      assert cache_control(conn) == @derived
    end

    test "on a released Media Kit picture gets it too", %{owner: owner, tmp: tmp} do
      photo = press_photo!(owner, tmp)

      conn = get(anonymous(), PressKit.url(photo, "large"))

      assert conn.status == 200
      assert cache_control(conn) == @derived
    end
  end

  describe "revalidating" do
    test "costs a 304 rather than the bytes while the reader is still allowed", %{
      owner: owner,
      tmp: tmp
    } do
      {_post, image} = post_photo!(owner, tmp)

      first = get(anonymous(), "/post_images/#{image.token}/feed.avif")
      assert first.status == 200
      assert byte_size(first.resp_body) > 0

      second =
        anonymous()
        |> put_req_header("if-none-match", etag(first))
        |> get("/post_images/#{image.token}/feed.avif")

      assert second.status == 304
      assert second.resp_body == ""
    end

    # What enforces this today is placement, not a check: the conditional lives
    # inside `ImageProxy.serve/3`, which no controller reaches before its own
    # `with` chain has authorized the reader. The test pins that against the
    # obvious future optimization — moving the ETag comparison into an endpoint
    # plug, in front of the authorization — rather than covering a live branch.
    test "answers a revoked reader 404, not 304, even when they hold the ETag", %{
      owner: owner,
      owner_conn: owner_conn,
      tmp: tmp
    } do
      {post, image} = post_photo!(owner, tmp)

      first = get(anonymous(), "/post_images/#{image.token}/feed.avif")
      assert first.status == 200
      tag = etag(first)

      Repo.insert!(%PostDenial{post_id: post.id, wildcard: "everyone"})

      revalidated =
        anonymous()
        |> put_req_header("if-none-match", tag)
        |> get("/post_images/#{image.token}/feed.avif")

      assert revalidated.status == 404

      # And the author, who may still see it, is not locked out by the same tag.
      # `recycle/1` because `put_req_header/3` — unlike `get/3` — does not do it
      # for you, and this conn has already carried the login response.
      assert owner_conn
             |> recycle()
             |> put_req_header("if-none-match", tag)
             |> get("/post_images/#{image.token}/feed.avif")
             |> Map.fetch!(:status) == 304
    end

    test "a frozen Media Kit picture 404s a browser holding its ETag", %{
      owner: owner,
      tmp: tmp
    } do
      photo = press_photo!(owner, tmp)

      first = get(anonymous(), PressKit.url(photo, "large"))
      assert first.status == 200
      tag = etag(first)

      :ok = Images.freeze(photo)

      assert anonymous()
             |> put_req_header("if-none-match", tag)
             |> get(PressKit.url(photo, "large"))
             |> Map.fetch!(:status) == 404
    end
  end

  describe "a file hand-over" do
    test "of a Media Kit original is never stored", %{owner: owner, tmp: tmp} do
      photo = press_photo!(owner, tmp)

      conn = get(anonymous(), PressKit.download_url(photo))

      assert conn.status == 200
      assert cache_control(conn) == @no_store
    end

    test "of a post photo's full-resolution original is never stored", %{owner: owner, tmp: tmp} do
      {_post, image} = post_photo!(owner, tmp, %{"download_original" => true})

      conn = get(anonymous(), "/post_images/#{image.token}/original.orig")

      assert conn.status == 200
      assert cache_control(conn) == @no_store
    end
  end
end
