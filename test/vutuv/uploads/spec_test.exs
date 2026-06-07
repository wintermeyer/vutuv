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
    assert Enum.map(Spec.versions(:avatar), & &1.name) == [:thumb, :medium]
    assert Spec.version(:avatar, :thumb).fit == {:crop, 96, 96, :center}
    assert Spec.version(:avatar, :medium).fit == {:crop, 192, 192, :center}
    assert Spec.version(:cover, :wide).fit == {:width_down, 1600}
    assert Spec.version(:screenshot, :thumb).fit == {:crop, 800, 528, :high}
    assert Enum.map(Spec.versions(:post_image), & &1.name) == [:thumb, :feed, :large]
    assert Spec.version(:post_image, :thumb).fit == {:crop, 320, 320, :center}
    assert Spec.version(:post_image, :feed).fit == {:box_down, 1200}
    assert Spec.version(:post_image, :large).fit == {:box_down, 1600}
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
  end
end
