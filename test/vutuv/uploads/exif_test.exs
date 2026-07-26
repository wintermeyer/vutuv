defmodule Vutuv.Uploads.ExifTest do
  @moduledoc """
  The camera-info parse (issue #1104). Two things matter here: the seven
  whitelisted facts come out in the photographic notation the panel shows, and
  a location in the file is *noticed* without any coordinate being read.
  """
  use ExUnit.Case, async: true

  alias Vix.Vips.MutableImage
  alias Vutuv.Uploads.Exif

  defp tmp! do
    tmp = Path.join(System.tmp_dir!(), "vutuv_exif_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    tmp
  end

  defp photo!(tmp, fields) do
    path = Path.join(tmp, "photo_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(40, 30, color: [10, 10, 10])

    {:ok, tagged} =
      Image.mutate(img, fn mut ->
        Enum.each(fields, fn {name, value} ->
          :ok = MutableImage.set(mut, name, :gchararray, value)
        end)
      end)

    {:ok, _} = Image.write(tagged, path)
    path
  end

  describe "read/1" do
    test "reads the whitelisted facts in photographic notation" do
      path =
        photo!(tmp!(), [
          {"exif-ifd0-Make", "Canon"},
          {"exif-ifd0-Model", "Canon EOS R6"},
          {"exif-ifd2-LensModel", "RF50mm F1.8 STM"},
          {"exif-ifd2-FocalLength", "50/1"},
          {"exif-ifd2-FNumber", "18/10"},
          {"exif-ifd2-ExposureTime", "1/200"},
          {"exif-ifd2-ISOSpeedRatings", "400"},
          {"exif-ifd2-DateTimeOriginal", "2026:07:25 14:32:07"}
        ])

      fields = Exif.read(path)

      assert fields.camera == "Canon EOS R6"
      assert fields.lens == "RF50mm F1.8 STM"
      assert fields.focal_length == "50"
      assert fields.aperture == "1.8"
      assert fields.shutter == "1/200"
      assert fields.iso == 400
      assert fields.taken_at == ~N[2026-07-25 14:32:07]
    end

    test "does not repeat the brand when the model already carries it" do
      path =
        photo!(tmp!(), [
          {"exif-ifd0-Make", "NIKON CORPORATION"},
          {"exif-ifd0-Model", "NIKON D850"}
        ])

      assert Exif.read(path).camera == "NIKON D850"
    end

    test "prefixes the make when the model stands alone" do
      path =
        photo!(tmp!(), [{"exif-ifd0-Make", "FUJIFILM"}, {"exif-ifd0-Model", "X-T5"}])

      assert Exif.read(path).camera == "FUJIFILM X-T5"
    end

    test "notices a location without reading a coordinate" do
      path =
        photo!(tmp!(), [
          {"exif-ifd0-Make", "Canon"},
          {"exif-ifd3-GPSLatitude", "50/1 56/1 0/1"},
          {"exif-ifd3-GPSLongitude", "6/1 57/1 0/1"}
        ])

      fields = Exif.read(path)

      assert fields.has_gps
      # The whole point: nothing in the parsed result says *where*.
      refute Enum.any?(Map.values(fields), &match?("50/1" <> _, to_string(&1)))
      refute Map.has_key?(fields, :latitude)
      refute Map.has_key?(fields, :longitude)
    end

    test "a photo with no location says so" do
      path = photo!(tmp!(), [{"exif-ifd0-Make", "Canon"}])
      refute Exif.read(path).has_gps
    end

    test "a file with no metadata at all yields empty fields, never an error" do
      path = photo!(tmp!(), [])
      fields = Exif.read(path)

      assert fields.camera == nil
      assert fields.iso == nil
      refute fields.has_gps
      assert Exif.summary(fields) == nil
    end

    test "an unreadable path yields empty fields rather than raising" do
      assert Exif.read("/nonexistent/nope.jpg").camera == nil
    end
  end

  describe "summary/1" do
    test "joins the facts the panel shows into one line" do
      summary =
        Exif.summary(%{
          camera: "Canon EOS R6",
          lens: "RF50mm F1.8 STM",
          focal_length: "50",
          aperture: "1.8",
          shutter: "1/200",
          iso: 400
        })

      assert summary == "Canon EOS R6 · RF50mm F1.8 STM · 50 mm · f/1.8 · 1/200 s · ISO 400"
    end

    test "skips what the photo does not carry" do
      assert Exif.summary(%{camera: "Leica M11", iso: 200}) == "Leica M11 · ISO 200"
    end

    test "answers nil when there is nothing to show, so callers ask once" do
      assert Exif.summary(%{camera: nil, iso: nil}) == nil
      assert Exif.summary(%{}) == nil
    end
  end
end
