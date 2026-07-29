defmodule Vutuv.Posts.PostImageCropTest do
  @moduledoc """
  The author's ratio crop on a post photo (issue: composer crop + bento).

  The contract under test is the privacy half as much as the geometry half:
  once a crop exists, the **uncropped** picture must not leave the server on
  any path — served versions, the original download and the link-preview JPEG
  all show the crop, and only the author-only `source` workbench (see
  `VutuvWeb.PostImageControllerTest`) still shows the full frame.
  """
  use Vutuv.DataCase

  alias Vutuv.PostImageStore
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias Vutuv.Repo

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_crop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:vutuv, :uploads_dir_prefix, prev),
        else: Application.delete_env(:vutuv, :uploads_dir_prefix)
    end)

    {:ok, tmp: tmp, user: insert(:user, email_confirmed?: true)}
  end

  defp pending_image!(user, tmp, width \\ 640, height \\ 480) do
    src = Path.join(tmp, "src-#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(width, height, color: [10, 200, 100])
    {:ok, _} = Image.write(img, src)
    {:ok, image} = Posts.create_pending_image(user, src, "photo.jpg")
    image
  end

  defp dimensions(path) do
    {:ok, img} = Image.open(path)
    {Image.width(img), Image.height(img)}
  end

  describe "Posts.crop_image/2" do
    test "re-derives every served version to the crop and stores the fractions", %{
      user: user,
      tmp: tmp
    } do
      image = pending_image!(user, tmp)

      assert {:ok, cropped} = Posts.crop_image(image, "0,0,0.5,0.5")

      assert cropped.crop == "0.0000,0.0000,0.5000,0.5000"
      assert cropped.width == 320
      assert cropped.height == 240

      assert {320, 240} = dimensions(PostImageStore.version_path(cropped, "feed"))
      # box_down never upscales, so the biggest version is simply the crop.
      assert {320, 240} = dimensions(PostImageStore.version_path(cropped, "xl"))
      # thumb stays its fixed square spec, cut from the cropped frame.
      assert {thumb_w, thumb_h} = dimensions(PostImageStore.version_path(cropped, "thumb"))
      assert thumb_w == thumb_h
    end

    test "a nil (or full-frame) crop resets to the whole picture", %{user: user, tmp: tmp} do
      image = pending_image!(user, tmp)
      {:ok, cropped} = Posts.crop_image(image, "0.25,0.25,0.5,0.5")
      assert cropped.crop

      assert {:ok, reset} = Posts.crop_image(cropped, nil)
      assert reset.crop == nil
      assert reset.width == 640
      assert reset.height == 480
      assert {640, 480} = dimensions(PostImageStore.version_path(reset, "feed"))

      {:ok, cropped} = Posts.crop_image(reset, "0.25,0.25,0.5,0.5")
      assert {:ok, reset} = Posts.crop_image(cropped, "0,0,1,1")
      assert reset.crop == nil
    end

    test "forces the exact-file download off: the upload must not leave once cropped", %{
      user: user,
      tmp: tmp
    } do
      image = pending_image!(user, tmp)

      {:ok, image} =
        Posts.update_image_settings(image, %{
          "download_original" => true,
          "download_exact" => true
        })

      assert image.download_exact

      {:ok, cropped} = Posts.crop_image(image, "0,0,0.5,0.5")
      refute cropped.download_exact
    end

    test "the exact file cannot be re-chosen while a crop is in force", %{user: user, tmp: tmp} do
      image = pending_image!(user, tmp)
      {:ok, cropped} = Posts.crop_image(image, "0,0,0.5,0.5")

      {:ok, updated} =
        Posts.update_image_settings(cropped, %{
          "download_original" => true,
          "download_exact" => true
        })

      refute updated.download_exact
    end
  end

  describe "the original download of a cropped photo" do
    test "serves a full-resolution crop, never the uncropped upload", %{user: user, tmp: tmp} do
      image = pending_image!(user, tmp)
      {:ok, image} = Posts.update_image_settings(image, %{"download_original" => true})
      {:ok, cropped} = Posts.crop_image(image, "0,0,0.5,0.5")

      assert {path, ".jpg"} = PostImageStore.download_file(cropped)
      assert {320, 240} = dimensions(path)
      # The file lives in the private originals tree, but is not the original.
      assert path =~ "originals/"
      refute path =~ "original.jpg"
    end

    test "ignores a stale exact-file flag rather than leaking the upload", %{
      user: user,
      tmp: tmp
    } do
      image = pending_image!(user, tmp)
      {:ok, cropped} = Posts.crop_image(image, "0,0,0.5,0.5")

      # Belt and braces: even if a row somehow still carries exact=true, the
      # download must fail closed to the cropped derivative.
      stale =
        cropped
        |> Ecto.Changeset.change(download_original: true, download_exact: true)
        |> Repo.update!()

      assert {path, ".jpg"} = PostImageStore.download_file(stale)
      assert {320, 240} = dimensions(path)
    end

    test "a re-crop invalidates the cached download", %{user: user, tmp: tmp} do
      image = pending_image!(user, tmp)
      {:ok, image} = Posts.update_image_settings(image, %{"download_original" => true})

      {:ok, cropped} = Posts.crop_image(image, "0,0,0.5,0.5")
      assert {_path, ".jpg"} = PostImageStore.download_file(cropped)

      {:ok, recropped} = Posts.crop_image(cropped, "0,0,0.25,0.25")
      assert {path, ".jpg"} = PostImageStore.download_file(recropped)
      assert {160, 120} = dimensions(path)
    end

    test "cleanable?/1 holds for a cropped photo (the derivative is always clean)", %{
      user: user,
      tmp: tmp
    } do
      image = pending_image!(user, tmp)
      {:ok, cropped} = Posts.crop_image(image, "0,0,0.5,0.5")
      assert PostImageStore.cleanable?(cropped)
    end
  end

  describe "the link-preview JPEG of a cropped photo" do
    test "shows the crop although it derives from the kept original", %{user: user, tmp: tmp} do
      image = pending_image!(user, tmp)
      {:ok, cropped} = Posts.crop_image(image, "0,0,0.5,0.5")

      assert {:ok, jpeg} = PostImageStore.og_jpeg(cropped)
      {:ok, decoded} = Image.from_binary(jpeg)
      assert Image.width(decoded) == 320
      assert Image.height(decoded) == 240
    end
  end

  describe "regeneration" do
    test "re-applies the persisted crop instead of silently un-cropping", %{
      user: user,
      tmp: tmp
    } do
      image = pending_image!(user, tmp)
      {:ok, cropped} = Posts.crop_image(image, "0,0,0.5,0.5")

      assert :ok = PostImageStore.regenerate(cropped, force: true)
      assert {320, 240} = dimensions(PostImageStore.version_path(cropped, "feed"))
    end
  end

  describe "PostImage.url/2 cache busting" do
    test "a cropped photo's URLs carry a crop-keyed version, an uncropped one's stay bare", %{
      user: user,
      tmp: tmp
    } do
      image = pending_image!(user, tmp)
      assert PostImage.url(image, "feed") == "/post_images/#{image.token}/feed.avif"

      {:ok, cropped} = Posts.crop_image(image, "0,0,0.5,0.5")
      assert PostImage.url(cropped, "feed") =~ ~r"/feed\.avif\?v=[\w-]+$"

      {:ok, recropped} = Posts.crop_image(cropped, "0,0,0.25,0.25")
      assert PostImage.url(recropped, "feed") != PostImage.url(cropped, "feed")

      {:ok, reset} = Posts.crop_image(recropped, nil)
      assert PostImage.url(reset, "feed") == "/post_images/#{image.token}/feed.avif"
    end
  end
end
