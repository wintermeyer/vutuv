defmodule Vutuv.Uploads.SpecTest do
  @moduledoc """
  Locks the central image-pipeline contract: every served version is AVIF,
  EXIF-autorotated **before** metadata stripping (orientation is EXIF — strip
  first and portrait phone photos render sideways) and fully stripped (GPS
  data must never reach a served file).

  The first test doubles as the **AVIF capability guard**: a libvips build
  without an AV1 encoder (libheif+aom) fails here loudly instead of at the
  first upload in production.
  """
  use ExUnit.Case, async: true

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage
  alias Vutuv.Uploads.Spec

  defp tmp! do
    tmp = Path.join(System.tmp_dir!(), "vutuv_spec_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    tmp
  end

  # A landscape JPEG carrying EXIF orientation 6 ("rotate 90° CW to display"),
  # a camera make, and GPS coordinates — the metadata that must not survive.
  defp exif_jpeg!(tmp) do
    path = Path.join(tmp, "source.jpg")
    {:ok, img} = Image.new(80, 40, color: [200, 30, 30])

    {:ok, tagged} =
      Image.mutate(img, fn mut ->
        :ok = MutableImage.set(mut, "orientation", :gint, 6)
        :ok = MutableImage.set(mut, "exif-ifd0-Make", :gchararray, "TestCam")
        :ok = MutableImage.set(mut, "exif-ifd2-GPSLatitude", :gchararray, "50/1 56/1 0/1")
      end)

    {:ok, _} = Image.write(tagged, path)
    path
  end

  defp exif_fields(path) do
    {:ok, image} = Image.open(path)
    {:ok, fields} = VipsImage.header_field_names(image)
    Enum.filter(fields, &String.contains?(&1, "exif"))
  end

  defp dims(path) do
    {:ok, image} = Image.open(path)
    {Image.width(image), Image.height(image)}
  end

  test "this libvips build can encode AVIF (deploy blocker if not)" do
    tmp = tmp!()
    dest = Path.join(tmp, "probe.avif")
    {:ok, rotated} = Spec.open_rotated(exif_jpeg!(tmp))
    spec = Spec.version(:post_image, :thumb)

    assert :ok = Spec.write_derived(spec, rotated, dest)
    # Re-open and materialize pixels: vips is lazy, a header-only check lies.
    {:ok, reopened} = Image.open(dest)
    assert {:ok, _binary} = VipsImage.write_to_binary(reopened)
  end

  test "the served extension is .avif" do
    assert Spec.served_ext() == ".avif"
  end

  test "canonical versions and resolutions per image type" do
    assert Enum.map(Spec.versions(:avatar), & &1.name) == [:thumb, :medium, :large]
    assert Spec.version(:avatar, :thumb).fit == {:crop, 96, 96, :center}
    assert Spec.version(:avatar, :medium).fit == {:crop, 192, 192, :center}
    # `large` is the profile header's click-to-enlarge (issue #1528): the one
    # avatar version sized for the lightbox rather than for a 96px slot.
    assert Spec.version(:avatar, :large).fit == {:crop_down, 1024, :center}
    assert Spec.version(:cover, :wide).fit == {:width_down, 1600}
    assert Spec.version(:screenshot, :thumb).fit == {:crop, 800, 528, :high}
    assert Enum.map(Spec.versions(:post_image), & &1.name) == [:thumb, :feed, :large, :xl]
    assert Spec.version(:post_image, :thumb).fit == {:crop, 320, 320, :center}
    assert Spec.version(:post_image, :feed).fit == {:box_down, 1200}
    assert Spec.version(:post_image, :large).fit == {:box_down, 1600}
    # `xl` is the lightbox version (issue #1104): the one size meant for
    # looking at rather than for a layout slot, so it is the only one big
    # enough to fill a 4K screen.
    assert Spec.version(:post_image, :xl).fit == {:box_down, 2560}
  end

  describe "write_derived/3" do
    test "strips all metadata (EXIF/GPS) from the derived file" do
      tmp = tmp!()
      dest = Path.join(tmp, "out.avif")
      {:ok, rotated} = Spec.open_rotated(exif_jpeg!(tmp))

      assert :ok = Spec.write_derived(Spec.version(:post_image, :feed), rotated, dest)
      assert exif_fields(dest) == []
    end

    test "autorotates before deriving: dimensions are post-rotation" do
      tmp = tmp!()
      dest = Path.join(tmp, "out.avif")
      # The 80x40 landscape carries orientation 6, so it *displays* as 40x80
      # portrait — and must be stored that way.
      {:ok, rotated} = Spec.open_rotated(exif_jpeg!(tmp))

      assert :ok = Spec.write_derived(Spec.version(:post_image, :large), rotated, dest)
      assert dims(dest) == {40, 80}
    end

    test "crop versions land exactly on their spec dimensions" do
      tmp = tmp!()
      dest = Path.join(tmp, "thumb.avif")
      {:ok, rotated} = Spec.open_rotated(exif_jpeg!(tmp))

      assert :ok = Spec.write_derived(Spec.version(:avatar, :thumb), rotated, dest)
      assert dims(dest) == {96, 96}
    end

    test "fit versions never upscale a smaller source" do
      tmp = tmp!()
      {:ok, rotated} = Spec.open_rotated(exif_jpeg!(tmp))

      box_dest = Path.join(tmp, "feed.avif")
      assert :ok = Spec.write_derived(Spec.version(:post_image, :feed), rotated, box_dest)
      assert dims(box_dest) == {40, 80}

      width_dest = Path.join(tmp, "wide.avif")
      assert :ok = Spec.write_derived(Spec.version(:cover, :wide), rotated, width_dest)
      assert dims(width_dest) == {40, 80}
    end

    # The avatar's `:large` has to keep two promises the plain `:crop` and the
    # plain `resize: :down` each keep only one of: square like the versions
    # beside it, and never invented pixels. Members hand us small avatars often
    # enough that both matter.
    test "crop_down squares a smaller source without upscaling it" do
      tmp = tmp!()
      dest = Path.join(tmp, "large.avif")
      # 80x40 landscape with orientation 6, so it displays as 40x80 portrait.
      {:ok, rotated} = Spec.open_rotated(exif_jpeg!(tmp))

      assert :ok = Spec.write_derived(Spec.version(:avatar, :large), rotated, dest)
      assert dims(dest) == {40, 40}
    end

    test "crop_down caps a larger source at its spec size" do
      tmp = tmp!()
      path = Path.join(tmp, "big.png")
      {:ok, big} = Image.new(2000, 1500, color: [20, 40, 60])
      {:ok, _} = Image.write(big, path)
      {:ok, rotated} = Spec.open_rotated(path)

      dest = Path.join(tmp, "large.avif")
      assert :ok = Spec.write_derived(Spec.version(:avatar, :large), rotated, dest)
      assert dims(dest) == {1024, 1024}
    end

    test "propagates encode errors instead of raising" do
      tmp = tmp!()
      {:ok, rotated} = Spec.open_rotated(exif_jpeg!(tmp))
      missing_dir = Path.join(tmp, "nope/out.avif")

      assert {:error, _} = Spec.write_derived(Spec.version(:avatar, :thumb), rotated, missing_dir)
    end
  end

  describe "open_rotated/1" do
    test "fails cleanly on a file that does not decode" do
      tmp = tmp!()
      path = Path.join(tmp, "fake.jpg")
      File.write!(path, "not actually a jpeg")

      assert {:error, _} = Spec.open_rotated(path)
    end

    test "rejects an image whose decoded size exceeds the megapixel cap" do
      tmp = tmp!()
      path = Path.join(tmp, "bomb.png")
      # 7500×7000 ≈ 52.5 MP of one color: a few KB on disk (a real
      # decompression-bomb shape), well over the 50 MP cap once decoded.
      {:ok, big} = Image.new(7500, 7000, color: [0, 0, 0])
      {:ok, _} = Image.write(big, path)

      assert {:error, :too_large} = Spec.open_rotated(path)
    end
  end
end
