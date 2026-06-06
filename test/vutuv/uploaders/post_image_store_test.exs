defmodule Vutuv.PostImageStoreTest do
  @moduledoc """
  Locks the post-image pipeline contract: every served version is WebP,
  EXIF-autorotated **before** metadata stripping (orientation is EXIF — strip
  first and portrait phone photos render sideways), and fully stripped (GPS
  data must never reach a served file). The original keeps its metadata and
  stays in the same private directory, which is never exposed directly.

  HEIC is capability-detected (the precompiled vix libvips lacks an HEVC
  decoder): the test asserts whichever behavior the running build must have,
  so a build that *claims* HEIC support but cannot decode fails loudly here
  instead of at the first iPhone upload in production.
  """
  # Not async: these tests set the global `:uploads_dir_prefix` application env.
  use ExUnit.Case, async: false

  alias Vutuv.PostImageStore
  alias Vutuv.Posts.PostImage

  @heic_fixture Path.join(:code.priv_dir(:vutuv), "heic_probe.heic")

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_post_image_#{System.unique_integer([:positive])}")
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

  # A landscape JPEG carrying EXIF orientation 6 ("rotate 90° CW to display"),
  # a camera make, and GPS coordinates — the metadata that must not survive.
  defp exif_jpeg!(tmp) do
    path = Path.join(tmp, "source.jpg")
    {:ok, img} = Image.new(80, 40, color: [200, 30, 30])

    {:ok, tagged} =
      Image.mutate(img, fn mut ->
        :ok = Vix.Vips.MutableImage.set(mut, "orientation", :gint, 6)
        :ok = Vix.Vips.MutableImage.set(mut, "exif-ifd0-Make", :gchararray, "TestCam")

        :ok =
          Vix.Vips.MutableImage.set(mut, "exif-ifd2-GPSLatitude", :gchararray, "50/1 56/1 0/1")
      end)

    {:ok, _} = Image.write(tagged, path)
    path
  end

  defp exif_fields(path) do
    {:ok, image} = Image.open(path)
    {:ok, fields} = Vix.Vips.Image.header_field_names(image)
    Enum.filter(fields, &String.contains?(&1, "exif"))
  end

  defp dims(path) do
    {:ok, image} = Image.open(path)
    {Image.width(image), Image.height(image)}
  end

  describe "store/3" do
    test "writes three WebP versions plus the private original", %{tmp: tmp} do
      token = PostImage.gen_token()

      assert {:ok, meta} = PostImageStore.store(exif_jpeg!(tmp), "photo.jpg", token)

      dir = Path.join([tmp, "post_images", token])
      assert File.exists?(Path.join(dir, "thumb.webp"))
      assert File.exists?(Path.join(dir, "feed.webp"))
      assert File.exists?(Path.join(dir, "large.webp"))
      assert File.exists?(Path.join(dir, "original.jpg"))

      assert meta.content_type == "image/jpeg"
      assert meta.size_bytes == File.stat!(Path.join(dir, "original.jpg")).size
    end

    test "autorotates before deriving: dimensions and pixels are post-rotation", %{tmp: tmp} do
      token = PostImage.gen_token()

      assert {:ok, meta} = PostImageStore.store(exif_jpeg!(tmp), "photo.jpg", token)

      # The 80x40 landscape carries orientation 6, so it *displays* as 40x80
      # portrait — and must be stored that way.
      assert {meta.width, meta.height} == {40, 80}
      large = Path.join([tmp, "post_images", token, "large.webp"])
      assert dims(large) == {40, 80}
    end

    test "strips all metadata from served versions, keeps it on the original", %{tmp: tmp} do
      token = PostImage.gen_token()

      assert {:ok, _meta} = PostImageStore.store(exif_jpeg!(tmp), "photo.jpg", token)

      dir = Path.join([tmp, "post_images", token])
      assert exif_fields(Path.join(dir, "thumb.webp")) == []
      assert exif_fields(Path.join(dir, "feed.webp")) == []
      assert exif_fields(Path.join(dir, "large.webp")) == []

      original_fields = exif_fields(Path.join(dir, "original.jpg"))
      assert "exif-ifd0-Make" in original_fields
    end

    test "does not upscale feed/large beyond the source size", %{tmp: tmp} do
      token = PostImage.gen_token()
      {:ok, _} = PostImageStore.store(exif_jpeg!(tmp), "photo.jpg", token)

      # Source displays at 40x80 — far below the 1200/1600 boxes.
      assert dims(Path.join([tmp, "post_images", token, "feed.webp"])) == {40, 80}
    end

    test "HEIC follows the build's actual decode capability", %{tmp: tmp} do
      token = PostImage.gen_token()

      if PostImageStore.heic_supported?() do
        assert ".heic" in PostImageStore.extension_whitelist()
        assert {:ok, meta} = PostImageStore.store(@heic_fixture, "sample.heic", token)
        assert meta.content_type == "image/heic"
        assert {meta.width, meta.height} == {400, 300}

        dir = Path.join([tmp, "post_images", token])
        assert File.exists?(Path.join(dir, "large.webp"))
        assert File.exists?(Path.join(dir, "original.heic"))
      else
        # No HEVC decoder in this libvips: HEIC must be refused up front
        # (whitelist) and the store must reject it cleanly, leaving no files.
        refute ".heic" in PostImageStore.extension_whitelist()
        assert {:error, :invalid_file} = PostImageStore.store(@heic_fixture, "sample.heic", token)
        refute File.exists?(Path.join([tmp, "post_images", token]))
      end
    end

    test "rejects non-whitelisted extensions", %{tmp: tmp} do
      path = Path.join(tmp, "anim.gif")
      File.mkdir_p!(tmp)
      File.write!(path, "GIF89a")

      assert {:error, :invalid_file} =
               PostImageStore.store(path, "anim.gif", PostImage.gen_token())
    end

    test "rejects files that do not decode, leaving nothing behind", %{tmp: tmp} do
      path = Path.join(tmp, "fake.jpg")
      File.mkdir_p!(tmp)
      File.write!(path, "not actually a jpeg")
      token = PostImage.gen_token()

      assert {:error, :invalid_file} = PostImageStore.store(path, "fake.jpg", token)
      refute File.exists?(Path.join([tmp, "post_images", token]))
    end
  end

  describe "version_path/2" do
    test "resolves served versions only, and only when the file exists", %{tmp: tmp} do
      token = PostImage.gen_token()
      {:ok, _} = PostImageStore.store(exif_jpeg!(tmp), "photo.jpg", token)
      image = %PostImage{token: token}

      assert PostImageStore.version_path(image, "large") ==
               Path.join([tmp, "post_images", token, "large.webp"])

      # The original is never resolvable through the serving API.
      assert PostImageStore.version_path(image, "original") == nil
      assert PostImageStore.version_path(%PostImage{token: PostImage.gen_token()}, "large") == nil
    end
  end

  describe "delete/1" do
    test "removes all stored files and tolerates absence", %{tmp: tmp} do
      token = PostImage.gen_token()
      {:ok, _} = PostImageStore.store(exif_jpeg!(tmp), "photo.jpg", token)

      assert :ok = PostImageStore.delete(token)
      refute File.exists?(Path.join([tmp, "post_images", token]))
      assert :ok = PostImageStore.delete(token)
    end

    test "refuses path-traversal tokens" do
      assert_raise MatchError, fn -> PostImageStore.delete("../evil") end
    end
  end
end
