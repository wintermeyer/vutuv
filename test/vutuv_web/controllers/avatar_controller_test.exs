defmodule VutuvWeb.AvatarControllerTest do
  @moduledoc """
  GET /:slug/avatar.jpg — the crawler-friendly avatar behind og:image
  (link-preview scrapers don't decode the served AVIF versions). Derived
  on the fly from the kept private original, metadata-stripped.
  """
  # Not async: points the global :uploads_dir_prefix at a tmp dir.
  use VutuvWeb.ConnCase, async: false

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_og_avatar_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:vutuv, :uploads_dir_prefix, prev),
        else: Application.delete_env(:vutuv, :uploads_dir_prefix)
    end)

    {:ok, conn: conn, tmp: tmp}
  end

  # A member with a really stored avatar (original on disk + DB column set),
  # uploaded from a generated JPEG carrying an EXIF tag.
  defp member_with_avatar do
    user = insert_activated_user(first_name: "Ava")

    src = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(600, 400, color: [10, 120, 200])

    {:ok, tagged} =
      Image.mutate(img, fn mut ->
        :ok = MutableImage.set(mut, "exif-ifd0-Make", :gchararray, "TestCam")
      end)

    {:ok, _} = Image.write(tagged, src)
    on_exit(fn -> File.rm(src) end)

    upload = %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
    {:ok, stored} = Vutuv.Avatar.store({upload, user})

    user |> Ecto.Changeset.change(avatar: stored) |> Repo.update!()
  end

  test "serves the avatar as a square, metadata-free JPEG", %{conn: conn} do
    user = member_with_avatar()

    conn = get(conn, "/#{user.active_slug}/avatar.jpg")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg; charset=utf-8"]
    assert [cache] = get_resp_header(conn, "cache-control")
    assert cache =~ "public"

    {:ok, jpeg} = Image.from_binary(conn.resp_body)
    assert {Image.width(jpeg), Image.height(jpeg)} == {512, 512}

    # The original's EXIF (camera, GPS, ...) must not leak into the
    # served derivative — same rule as the AVIF pipeline.
    {:ok, fields} = VipsImage.header_field_names(jpeg)
    assert Enum.filter(fields, &String.contains?(&1, "exif")) == []
  end

  test "404 for members without an avatar, unknown and unactivated slugs", %{conn: conn} do
    bare = insert_activated_user()
    assert get(conn, "/#{bare.active_slug}/avatar.jpg").status == 404

    assert get(conn, "/nobody_here/avatar.jpg").status == 404

    sleepy = insert_activated_user(activated?: false, avatar: "selfie.jpg")
    assert get(conn, "/#{sleepy.active_slug}/avatar.jpg").status == 404
  end
end
