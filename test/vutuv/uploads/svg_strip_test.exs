defmodule Vutuv.Uploads.SvgStripTest do
  @moduledoc """
  The vector half of the "a download carries nothing but the picture" promise
  (issue #2145).

  Two things are worth a test here, and they pull against each other: the
  editor's trail really is gone, and the drawing really is untouched. The second
  is the one that could go wrong quietly — a logo that renders a hair different
  is a defect nobody notices until it is in a newspaper — so every case that
  keeps bytes asserts the bytes, and the cases that remove something rasterise
  both files and compare the pixels.
  """
  use ExUnit.Case, async: true

  alias Vix.Vips.MutableImage
  alias Vutuv.Uploads.Spec
  alias Vutuv.Uploads.SvgStrip

  # A JPEG carrying the whole spread the Media Kit promises to remove, as an
  # SVG carries one: base64, inside an `xlink:href`.
  defp tagged_jpeg do
    {:ok, image} = Image.new(60, 40, color: [10, 120, 200])

    {:ok, tagged} =
      Image.mutate(image, fn mut ->
        :ok = MutableImage.set(mut, "exif-ifd0-Make", :gchararray, "Canon")
        :ok = MutableImage.set(mut, "exif-ifd0-Model", :gchararray, "Canon EOS R5")
        :ok = MutableImage.set(mut, "exif-ifd0-Artist", :gchararray, "Ada King")
        :ok = MutableImage.set(mut, "exif-ifd2-BodySerialNumber", :gchararray, "SN-CLAUDE-1234")
        :ok = MutableImage.set(mut, "exif-ifd3-GPSLatitude", :gchararray, "52/1 31/1 12/1")
      end)

    {:ok, binary} = Image.write(tagged, :memory, suffix: ".jpg")
    binary
  end

  describe "what comes out" do
    test "the editor's whole trail is gone, and the drawing is not" do
      markup = """
      <?xml version="1.0" encoding="UTF-8" standalone="no"?>
      <!-- Generator: Adobe Illustrator 28.0.0, SVG Export Plug-In -->
      <svg xmlns="http://www.w3.org/2000/svg"
         xmlns:dc="http://purl.org/dc/elements/1.1/"
         xmlns:cc="http://creativecommons.org/ns#"
         xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.0.dtd"
         xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape"
         width="240" height="80" viewBox="0 0 240 80"
         inkscape:version="1.3.2 (091e20e)"
         sodipodi:docname="/Users/ada.king/kunden/acme-logo-final.svg">
        <title>Acme wordmark</title>
        <desc>Blue on white.</desc>
        <sodipodi:namedview id="base" inkscape:current-layer="layer1" />
        <metadata id="metadata5">
          <rdf:RDF><cc:Work rdf:about="">
            <dc:creator><cc:Agent><dc:title>Ada King &lt;ada@example.org&gt;</dc:title></cc:Agent></dc:creator>
            <dc:rights><cc:Agent><dc:title>internal draft, do not publish</dc:title></cc:Agent></dc:rights>
          </cc:Work></rdf:RDF>
        </metadata>
        <g inkscape:label="Layer 1" inkscape:groupmode="layer" id="layer1">
          <rect x="0" y="0" width="240" height="80" fill="#ffffff" id="bg" />
          <text x="20" y="56" font-size="40" fill="#0b3d91">ACME</text>
        </g>
      </svg>
      """

      assert {:ok, cleaned} = SvgStrip.clean(markup)

      for gone <- [
            "Ada King",
            "ada@example.org",
            "do not publish",
            "acme-logo-final.svg",
            "/Users/ada.king",
            "Adobe Illustrator",
            "inkscape",
            "sodipodi",
            "<metadata",
            "rdf:RDF"
          ] do
        refute String.contains?(cleaned, gone), "#{gone} survived"
      end

      # The drawing, and the two elements a reader hears, are still there.
      assert cleaned =~ ~s(<rect x="0" y="0" width="240" height="80" fill="#ffffff" id="bg" />)
      assert cleaned =~ "<text x=\"20\" y=\"56\" font-size=\"40\" fill=\"#0b3d91\">ACME</text>"
      assert cleaned =~ "<title>Acme wordmark</title>"
      assert cleaned =~ "<desc>Blue on white.</desc>"
      assert cleaned =~ ~s(<?xml version="1.0" encoding="UTF-8" standalone="no"?>)
      assert cleaned =~ ~s(xmlns="http://www.w3.org/2000/svg")

      assert SvgStrip.renders_alike?(markup, cleaned)
    end

    test "an embedded photograph is cleaned where it lies, and still draws the same" do
      jpeg = tagged_jpeg()
      assert String.contains?(jpeg, "SN-CLAUDE-1234")

      markup = """
      <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
           width="240" height="80" viewBox="0 0 240 80">
        <image x="8" y="8" width="60" height="40" xlink:href="data:image/jpeg;base64,#{Base.encode64(jpeg)}" />
      </svg>
      """

      assert {:ok, cleaned} = SvgStrip.clean(markup)

      [_, payload] = Regex.run(~r/base64,([A-Za-z0-9+\/=]+)"/, cleaned)
      embedded = Base.decode64!(payload)

      refute String.contains?(embedded, "SN-CLAUDE-1234")
      refute String.contains?(embedded, "Canon EOS R5")
      refute String.contains?(embedded, "Ada King")
      refute String.contains?(embedded, "Exif")
      assert byte_size(embedded) < byte_size(jpeg)

      assert SvgStrip.renders_alike?(markup, cleaned)
    end

    test "a file with nothing to remove comes back byte for byte" do
      markup =
        ~s(<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10' >) <>
          ~s(<desc>A &amp; B</desc><rect width="10" height="10" fill="#000"/></svg>\n)

      assert SvgStrip.clean(markup) == {:ok, markup}
    end
  end

  describe "what it refuses" do
    test "a DOCTYPE, where an entity would be declared" do
      markup =
        ~s(<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x "y">]>) <>
          ~s(<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>)

      assert SvgStrip.clean(markup) == :error
    end

    test "bytes that are not the SVG their name claims" do
      assert SvgStrip.clean(<<137, "PNG\r\n", 26, 10, 0, 0>>) == :error
    end

    test "an embedded file no container stripper can take apart" do
      font = Base.encode64("wOFF" <> :binary.copy(<<0>>, 40))

      markup =
        ~s(<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4">) <>
          ~s(<style>@font-face{src:url\(data:font/woff;base64,#{font}\)}</style></svg>)

      assert SvgStrip.clean(markup) == :error
    end

    test "an embedded file that is not base64 at all" do
      markup =
        ~s(<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink") <>
          ~s( width="4" height="4"><image xlink:href="data:image/svg+xml,%3Csvg%2F%3E"/></svg>)

      assert SvgStrip.clean(markup) == :error
    end

    test "markup it cannot parse" do
      assert SvgStrip.clean(~s(<svg xmlns="http://www.w3.org/2000/svg" width=4></svg>)) == :error
    end
  end

  describe "the corners of the scanner" do
    test "a `</metadata>` inside CDATA does not end the removal early" do
      markup =
        ~s(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">) <>
          ~s(<metadata><![CDATA[</metadata> Ada King]]></metadata>) <>
          ~s(<rect width="10" height="10" fill="#123456"/></svg>)

      assert {:ok, cleaned} = SvgStrip.clean(markup)
      refute String.contains?(cleaned, "Ada King")
      assert cleaned =~ ~s(<rect width="10" height="10" fill="#123456"/>)
    end

    test "an unprefixed element in a foreign default namespace goes with its subtree" do
      markup =
        ~s(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">) <>
          ~s(<sfw xmlns="http://ns.adobe.com/SaveForWeb/1.0/"><slices>Ada King</slices></sfw>) <>
          ~s(<rect width="10" height="10" fill="#123456"/></svg>)

      assert {:ok, cleaned} = SvgStrip.clean(markup)
      refute String.contains?(cleaned, "Ada King")
      assert cleaned =~ "<rect"
    end

    test "a prefix rebound deeper in the tree is read where it is used" do
      markup =
        ~s(<svg xmlns="http://www.w3.org/2000/svg") <>
          ~s( xmlns:x="http://www.inkscape.org/namespaces/inkscape" width="10" height="10">) <>
          ~s(<g x:note="outer-drops">) <>
          ~s(<g xmlns:x="http://www.w3.org/2000/svg" x:note="inner-keeps"></g>) <>
          ~s(</g><g x:note="outer-drops-again"></g>) <>
          ~s(<rect width="10" height="10" fill="#123456"/></svg>)

      assert {:ok, cleaned} = SvgStrip.clean(markup)

      refute String.contains?(cleaned, "outer-drops")
      refute String.contains?(cleaned, "outer-drops-again")
      assert cleaned =~ ~s(x:note="inner-keeps")
      assert SvgStrip.renders_alike?(markup, cleaned)
    end

    # Measured, not assumed: librsvg refuses a document with an undeclared
    # prefix before this module gets to decide anything about it, so the
    # `xlink` binding `@root_scope` carries is belt and braces rather than a
    # case a stored file can be in.
    test "an undeclared prefix is refused by the renderer, so the file is refused too" do
      markup =
        ~s(<svg xmlns="http://www.w3.org/2000/svg" width="60" height="40">) <>
          ~s(<image width="60" height="40" xlink:href="#none"/></svg>)

      assert {:error, reason} = Spec.open_rotated_binary(markup)
      assert reason =~ "Namespace prefix xlink"
      assert SvgStrip.clean(markup) == :error
    end
  end

  describe "the render check" do
    # Calibration on the shipped instrument, not a copy of it: a comparison that
    # answered `true` for everything would read as "nothing ever drifts", and
    # every assertion above would be worthless.
    test "two different drawings do not raster alike" do
      one = ~s(<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8" />)

      other =
        ~s(<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">) <>
          ~s(<rect width="8" height="8" fill="#ff0000"/></svg>)

      refute SvgStrip.renders_alike?(one, other)
      assert SvgStrip.renders_alike?(one, one)
    end
  end
end
