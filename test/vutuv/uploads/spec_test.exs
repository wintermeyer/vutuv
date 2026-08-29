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
  alias Vix.Vips.Operation
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

  # A store that derives from a version list its own URL layer does not know
  # writes files nothing can ever serve. `OrganizationImageStore` derived from
  # `:post_image`, whose fourth `xl` entry is the 2560px lightbox version — so
  # every logo, cover and gallery shot paid for the most expensive AVIF encode
  # of the four and kept it for ever, unreachable: the proxy whitelist,
  # `version_path/2` and `accel_path/2` all guard on the store's own three
  # names. Pinning the pair here is what keeps them from drifting again.
  test "every store derives exactly the versions it can serve" do
    # Read off the store's own source, because the bug was the *key it passes*:
    # comparing `Spec.versions(:organization_image)` with the whitelist would
    # have agreed happily while the store derived from `:post_image` beside it.
    for {source, whitelist, type} <- [
          {"lib/vutuv/uploaders/organization_image_store.ex", Vutuv.OrganizationImageStore,
           :organization_image},
          {"lib/vutuv/uploaders/post_image_store.ex", Vutuv.Posts.PostImage, :post_image}
        ] do
      keys =
        ~r/Spec\.(?:write_all|versions)\(:(\w+)/
        |> Regex.scan(File.read!(source), capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      assert keys == [to_string(type)],
             "#{source} derives from #{inspect(keys)}; its URL layer serves " <>
               "only #{inspect(type)}'s versions"

      derived = Spec.versions(type) |> Enum.map(&to_string(&1.name)) |> Enum.sort()
      served = whitelist.versions() |> Enum.map(&to_string/1) |> Enum.sort()

      assert derived == served,
             "#{inspect(whitelist)} serves #{inspect(served)} but #{inspect(type)} " <>
               "derives #{inspect(derived)}"
    end
  end

  # The two page-picture lists are one list under two names, so they cannot
  # answer differently for the same slot.
  test "a job posting's picture and a page's picture want the same slots" do
    assert Spec.versions(:organization_image) == Spec.versions(:job_posting_image)
    assert Enum.map(Spec.versions(:organization_image), & &1.name) == [:thumb, :feed, :large]
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

  describe "write_pixelated/2" do
    # A 2px checkerboard: the finest detail an image can carry, and a source
    # whose "is the detail still there" question has one number for an answer
    # (its standard deviation, 127.5 — half the pixels black, half white).
    defp checkerboard!(side) do
      {:ok, tile} =
        VipsImage.new_from_binary(
          <<0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0>>,
          2,
          2,
          3,
          :VIPS_FORMAT_UCHAR
        )

      {:ok, checker} = Operation.replicate(tile, div(side, 2), div(side, 2))
      checker
    end

    defp stddev(path) do
      {:ok, image} = Image.open(path)
      {:ok, deviation} = Operation.deviate(image)
      deviation
    end

    test "throws the detail away rather than covering it up" do
      tmp = tmp!()
      checker = checkerboard!(320)
      pixelated = Path.join(tmp, "pixelated.avif")
      feed = Path.join(tmp, "feed.avif")

      assert :ok = Spec.write_pixelated(checker, pixelated)
      assert :ok = Spec.write_derived(Spec.version(:post_image, :feed), checker, feed)

      # The calibration that makes the pixelated preview number mean something: the very
      # same pixels through the very same AVIF encoder keep every bit of their
      # detail in a served version (127.5, the source's own figure), so a
      # near-zero reading on the pixelated preview is the shrink having averaged the
      # detail away and not the codec quietly smoothing everything.
      assert stddev(feed) > 100
      assert stddev(pixelated) < 5
    end

    test "keeps the aspect ratio and blows the cells up to a fixed long edge" do
      tmp = tmp!()
      {:ok, wide} = Image.new(1200, 600, color: [10, 120, 200])
      dest = Path.join(tmp, "wide.avif")

      assert :ok = Spec.write_pixelated(wide, dest)
      # 64 cells on the long edge, each blown up 15x: 960x480.
      assert dims(dest) == {960, 480}
    end

    test "carries no metadata out of the original" do
      tmp = tmp!()
      {:ok, rotated} = Spec.open_rotated(exif_jpeg!(tmp))
      dest = Path.join(tmp, "stripped.avif")

      assert :ok = Spec.write_pixelated(rotated, dest)
      assert exif_fields(dest) == []
    end

    test "propagates encode errors instead of raising" do
      tmp = tmp!()
      {:ok, rotated} = Spec.open_rotated(exif_jpeg!(tmp))

      assert {:error, _} = Spec.write_pixelated(rotated, Path.join(tmp, "nope/out.avif"))
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

  describe "SVG" do
    @svg ~s(<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">) <>
           ~s(<rect width="64" height="64" fill="#1b1408"/></svg>)

    # The capability guard for SVG, the sibling of the AVIF one above: without
    # librsvg the organization logo field silently stops offering the format,
    # and a build losing it should say so here rather than on someone's upload.
    test "this libvips build can rasterise SVG" do
      assert Spec.svg_supported?()
    end

    test "renders at the raster size, not at the size the file names" do
      tmp = tmp!()
      path = Path.join(tmp, "logo.svg")
      File.write!(path, @svg)

      assert {:ok, image} = Spec.open_rotated(path)
      assert Image.width(image) == Spec.svg_raster_size()
    end

    # The extension is not what routes a file to the SVG renderer — libvips
    # sniffs the content — so neither is it what routes one to the vetting.
    test "an SVG named .png is still rasterised and still vetted" do
      tmp = tmp!()
      path = Path.join(tmp, "logo.png")
      File.write!(path, @svg)

      assert {:ok, image} = Spec.open_rotated(path)
      assert Image.width(image) == Spec.svg_raster_size()

      File.write!(path, String.replace(@svg, "<rect", "<script>x</script><rect"))
      assert {:error, :unsafe_svg} = Spec.open_rotated(path)
    end

    test "refuses markup that carries code, an entity or an external reference" do
      tmp = tmp!()
      path = Path.join(tmp, "hostile.svg")

      for hostile <- [
            String.replace(@svg, "<rect", "<script>x</script><rect"),
            String.replace(@svg, "<rect", ~s(<foreignObject><b>hi</b></foreignObject><rect)),
            ~s(<!DOCTYPE svg [<!ENTITY x "y">]>) <> @svg,
            String.replace(@svg, "<rect", ~s(<image href="file:///etc/passwd"/><rect)),
            String.replace(@svg, "<rect", ~s(<image xlink:href="https://example.com/x"/><rect)),
            String.replace(@svg, "<rect", ~s|<style>@import url(x.css);</style><rect|)
          ] do
        File.write!(path, hostile)
        assert {:error, :unsafe_svg} = Spec.open_rotated(path), "accepted: #{hostile}"
      end
    end

    # What an editor exports: namespace URLs and Creative-Commons metadata,
    # none of it fetched. A blanket URL ban would refuse ordinary logos.
    test "accepts the URLs an editor writes into a file it never fetches" do
      tmp = tmp!()
      path = Path.join(tmp, "inkscape.svg")

      File.write!(path, """
      <svg xmlns="http://www.w3.org/2000/svg" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:cc="http://creativecommons.org/ns#" width="64" height="64">
        <metadata><rdf:RDF><cc:License rdf:about="http://creativecommons.org/licenses/by/4.0/"/></rdf:RDF></metadata>
        <rect width="64" height="64" fill="#1b1408"/>
      </svg>
      """)

      assert {:ok, _image} = Spec.open_rotated(path)
    end

    # Bytes reach the pipeline from remote servers too (a fediverse attachment,
    # a book cover), and that door has its own decode.
    test "open_rotated_binary/1 rasterises and vets the same way" do
      assert {:ok, image} = Spec.open_rotated_binary(@svg)
      assert Image.width(image) == Spec.svg_raster_size()

      hostile = String.replace(@svg, "<rect", "<script>x</script><rect")
      assert {:error, :unsafe_svg} = Spec.open_rotated_binary(hostile)
    end
  end
end
