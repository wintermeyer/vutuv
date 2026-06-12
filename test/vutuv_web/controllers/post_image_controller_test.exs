defmodule VutuvWeb.PostImageControllerTest do
  @moduledoc """
  The authorizing image proxy: a post's audience must guard its image bytes,
  pending uploads must stay private to their uploader, and the original must
  never be resolvable. Denied and unknown both answer 404 (no existence
  leak).
  """
  use VutuvWeb.ConnCase

  alias Vix.Vips.MutableImage
  alias Vutuv.Posts

  @other_login_attrs %{
    "emails" => %{"0" => %{"value" => "other@example.com"}},
    "first_name" => "other"
  }

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_proxy_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:vutuv, :uploads_dir_prefix, prev),
        else: Application.delete_env(:vutuv, :uploads_dir_prefix)
    end)

    {:ok, tmp: tmp}
  end

  defp pending_image!(user, tmp) do
    src = Path.join(tmp, "src-#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(64, 64, color: [10, 200, 100])
    {:ok, _} = Image.write(img, src)
    {:ok, image} = Posts.create_pending_image(user, src, "photo.jpg")
    image
  end

  defp post_with_image!(author, tmp, attrs \\ %{}) do
    image = pending_image!(author, tmp)

    {:ok, post} =
      Posts.create_post(author, Map.merge(%{body: "pic", image_ids: [image.id]}, attrs))

    {post, image}
  end

  describe "a public post's image" do
    test "is served to anonymous visitors with immutable private caching", %{conn: conn, tmp: tmp} do
      author = insert(:user, activated?: true)
      {_post, image} = post_with_image!(author, tmp)

      conn = get(conn, "/post_images/#{image.token}/feed.avif")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/avif"
      assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
    end

    test "a legacy .webp URL (old post bodies, bookmarks) still serves the stored file", %{
      conn: conn,
      tmp: tmp
    } do
      author = insert(:user, activated?: true)
      {_post, image} = post_with_image!(author, tmp)

      conn = get(conn, "/post_images/#{image.token}/feed.webp")

      assert conn.status == 200
      # The on-disk file is AVIF; the content type follows the bytes, not the URL.
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/avif"
    end
  end

  describe "denied requests" do
    test "unknown token is a 404", %{conn: conn} do
      assert get(conn, "/post_images/nosuchtoken/feed.avif").status == 404
    end

    test "only served versions resolve — the original never does", %{conn: conn, tmp: tmp} do
      author = insert(:user, activated?: true)
      {_post, image} = post_with_image!(author, tmp)

      assert get(conn, "/post_images/#{image.token}/original.jpg").status == 404
      assert get(conn, "/post_images/#{image.token}/original.avif").status == 404
      assert get(conn, "/post_images/#{image.token}/original.webp").status == 404
      assert get(conn, "/post_images/#{image.token}/feed.png").status == 404
    end

    test "a restricted post's image is hidden from anonymous, served to members", %{
      conn: conn,
      tmp: tmp
    } do
      author = insert(:user, activated?: true)

      {_post, image} =
        post_with_image!(author, tmp, %{denials: [%{"wildcard" => "logged_out"}]})

      assert get(conn, "/post_images/#{image.token}/feed.avif").status == 404

      {member_conn, _member} = create_and_login_user(conn)
      assert get(member_conn, "/post_images/#{image.token}/feed.avif").status == 200
    end

    test "a pending image is visible to its uploader alone", %{conn: conn, tmp: tmp} do
      {uploader_conn, uploader} = create_and_login_user(conn)
      image = pending_image!(uploader, tmp)

      assert get(uploader_conn, "/post_images/#{image.token}/thumb.avif").status == 200

      other_conn =
        Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})

      {other_conn, _other} = create_and_login_user(other_conn, @other_login_attrs)
      assert get(other_conn, "/post_images/#{image.token}/thumb.avif").status == 404

      anonymous = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})
      assert get(anonymous, "/post_images/#{image.token}/thumb.avif").status == 404
    end
  end

  # og.jpg is the link-preview version (og:image — scrapers don't decode
  # AVIF): derived from the original on the fly, width-capped, stripped.
  # Same authorization as every other version.
  describe "the og.jpg link-preview version" do
    test "serves a width-capped, metadata-free JPEG to anonymous visitors", %{
      conn: conn,
      tmp: tmp
    } do
      author = insert(:user, activated?: true)

      # A wide source carrying EXIF that must not survive into the JPEG.
      src = Path.join(tmp, "wide.jpg")
      {:ok, img} = Image.new(2000, 500, color: [10, 120, 200])

      {:ok, tagged} =
        Image.mutate(img, fn mut ->
          :ok = MutableImage.set(mut, "exif-ifd0-Make", :gchararray, "TestCam")
        end)

      {:ok, _} = Image.write(tagged, src)
      {:ok, image} = Posts.create_pending_image(author, src, "wide.jpg")
      {:ok, _post} = Posts.create_post(author, %{body: "pic", image_ids: [image.id]})

      conn = get(conn, "/post_images/#{image.token}/og.jpg")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"
      assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]

      {:ok, jpeg} = Image.from_binary(conn.resp_body)
      assert {Image.width(jpeg), Image.height(jpeg)} == {1200, 300}
      assert {Image.width(jpeg), Image.height(jpeg)} == Vutuv.PostImageStore.og_dimensions(image)

      {:ok, fields} = Vix.Vips.Image.header_field_names(jpeg)
      assert Enum.filter(fields, &String.contains?(&1, "exif")) == []
    end

    test "a small image is never upscaled", %{conn: conn, tmp: tmp} do
      author = insert(:user, activated?: true)
      {_post, image} = post_with_image!(author, tmp)

      conn = get(conn, "/post_images/#{image.token}/og.jpg")

      assert conn.status == 200
      {:ok, jpeg} = Image.from_binary(conn.resp_body)
      assert {Image.width(jpeg), Image.height(jpeg)} == {64, 64}
    end

    test "is guarded by the post's audience like every version", %{conn: conn, tmp: tmp} do
      author = insert(:user, activated?: true)

      {_post, image} =
        post_with_image!(author, tmp, %{denials: [%{"wildcard" => "logged_out"}]})

      assert get(conn, "/post_images/#{image.token}/og.jpg").status == 404
    end

    test "falls back to a served version when the original is missing", %{conn: conn, tmp: tmp} do
      author = insert(:user, activated?: true)
      {_post, image} = post_with_image!(author, tmp)
      File.rm_rf!(Path.join(tmp, "originals"))

      assert get(conn, "/post_images/#{image.token}/og.jpg").status == 200
    end

    test "404 when nothing usable is on disk", %{conn: conn, tmp: tmp} do
      author = insert(:user, activated?: true)
      {_post, image} = post_with_image!(author, tmp)
      File.rm_rf!(tmp)

      assert get(conn, "/post_images/#{image.token}/og.jpg").status == 404
    end
  end

  describe "production serving mode" do
    test "answers with X-Accel-Redirect instead of the file", %{conn: conn, tmp: tmp} do
      Application.put_env(:vutuv, :post_image_serving, :accel_redirect)
      on_exit(fn -> Application.delete_env(:vutuv, :post_image_serving) end)

      author = insert(:user, activated?: true)
      {_post, image} = post_with_image!(author, tmp)

      conn = get(conn, "/post_images/#{image.token}/large.avif")

      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/avif"

      assert get_resp_header(conn, "x-accel-redirect") ==
               ["/internal_post_images/#{image.token}/large.avif"]
    end

    test "a legacy .webp URL accel-redirects to the resolved on-disk file", %{
      conn: conn,
      tmp: tmp
    } do
      Application.put_env(:vutuv, :post_image_serving, :accel_redirect)
      on_exit(fn -> Application.delete_env(:vutuv, :post_image_serving) end)

      author = insert(:user, activated?: true)
      {_post, image} = post_with_image!(author, tmp)

      # The store wrote .avif files, so the legacy URL redirects to those.
      conn = get(conn, "/post_images/#{image.token}/large.webp")

      assert get_resp_header(conn, "x-accel-redirect") ==
               ["/internal_post_images/#{image.token}/large.avif"]
    end
  end
end
