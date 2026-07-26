defmodule Vutuv.Uploads.MetadataStripTest do
  @moduledoc """
  The two promises the "just the picture" download rests on (issue #1104):
  every metadata block is gone, and the compressed image data is byte-for-byte
  what was uploaded.

  The second half is the one worth a test: a re-encode would also remove the
  metadata, and would also look fine — it would just quietly cost the
  photographer quality on the file they hand a client.
  """
  use ExUnit.Case, async: true

  alias Vix.Vips.MutableImage
  alias Vutuv.Uploads.MetadataStrip

  defp tmp! do
    tmp = Path.join(System.tmp_dir!(), "vutuv_strip_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    tmp
  end

  # A file carrying the whole spread we promise to remove: a location, a body
  # serial number, the owner's name and a text comment.
  defp tagged!(tmp, name, writer) do
    path = Path.join(tmp, name)
    {:ok, img} = Image.new(60, 40, color: [10, 120, 200])

    {:ok, tagged} =
      Image.mutate(img, fn mut ->
        :ok = MutableImage.set(mut, "exif-ifd0-Make", :gchararray, "TestCam")
        :ok = MutableImage.set(mut, "exif-ifd0-Artist", :gchararray, "Ada King")
        :ok = MutableImage.set(mut, "exif-ifd2-BodySerialNumber", :gchararray, "SN-12345")
        :ok = MutableImage.set(mut, "exif-ifd3-GPSLatitude", :gchararray, "50/1 56/1 0/1")
        :ok = writer.(mut)
      end)

    {:ok, _} = Image.write(tagged, path)
    path
  end

  defp no_op(_mut), do: :ok

  describe "strip_binary/1 on a JPEG" do
    setup do
      tmp = tmp!()
      path = tagged!(tmp, "photo.jpg", &no_op/1)
      %{tmp: tmp, path: path, original: File.read!(path)}
    end

    test "removes every metadata marker segment", %{path: path} do
      cleaned = MetadataStrip.strip(path, ".jpg")

      refute cleaned == :unsupported
      refute String.contains?(cleaned, "GPS")
      refute String.contains?(cleaned, "SN-12345")
      refute String.contains?(cleaned, "Ada King")
      refute String.contains?(cleaned, "TestCam")
      # "Exif\0\0" is the APP1 identifier; no APPn segment may survive.
      refute String.contains?(cleaned, "Exif")
    end

    test "keeps the compressed scan byte-for-byte (no re-encode)", %{original: original} do
      cleaned = MetadataStrip.strip_binary(original)

      assert scan(cleaned) == scan(original)
      # …and it really did get smaller, i.e. the test above is not passing
      # because nothing was stripped in the first place.
      assert byte_size(cleaned) < byte_size(original)
    end

    test "the result is still a decodable image of the same size", %{tmp: tmp, original: original} do
      out = Path.join(tmp, "cleaned.jpg")
      File.write!(out, MetadataStrip.strip_binary(original))

      {:ok, image} = Image.open(out)
      assert Image.width(image) == 60
      assert Image.height(image) == 40
    end

    test "a truncated file is refused rather than half-copied", %{original: original} do
      half = binary_part(original, 0, div(byte_size(original), 2))
      assert MetadataStrip.strip_binary(half) == :unsupported
    end

    # Everything from the start-of-scan marker to the end of the file is the
    # entropy-coded image data. Comparing it is how "pixels untouched" is
    # checked without decoding anything.
    defp scan(binary) do
      case :binary.match(binary, <<0xFF, 0xDA>>) do
        {at, _len} -> binary_part(binary, at, byte_size(binary) - at)
        :nomatch -> flunk("no start-of-scan marker in the JPEG")
      end
    end
  end

  describe "strip_binary/1 on a PNG" do
    test "drops the EXIF chunk and stays decodable" do
      tmp = tmp!()
      path = tagged!(tmp, "photo.png", &no_op/1)
      cleaned = MetadataStrip.strip(path, ".png")

      refute cleaned == :unsupported
      refute String.contains?(cleaned, "GPS")
      refute String.contains?(cleaned, "Ada King")
      # The image data chunk is untouched.
      assert String.contains?(cleaned, "IDAT")

      out = Path.join(tmp, "cleaned.png")
      File.write!(out, cleaned)
      {:ok, image} = Image.open(out)
      assert Image.width(image) == 60
    end
  end

  describe "strip_binary/1 on a WebP" do
    test "drops the EXIF chunk, fixes the RIFF size and stays decodable" do
      tmp = tmp!()
      path = tagged!(tmp, "photo.webp", &no_op/1)
      cleaned = MetadataStrip.strip(path, ".webp")

      refute cleaned == :unsupported
      refute String.contains?(cleaned, "GPS")
      refute String.contains?(cleaned, "Ada King")

      # A RIFF file declares its own length; a stripped chunk that left the
      # header lying would make the file broken for strict decoders.
      <<"RIFF", declared::little-32, rest::binary>> = cleaned
      assert declared == byte_size(rest)

      out = Path.join(tmp, "cleaned.webp")
      File.write!(out, cleaned)
      {:ok, image} = Image.open(out)
      assert Image.width(image) == 60
    end
  end

  describe "supported?/1" do
    test "answers for the formats the download route may offer" do
      assert MetadataStrip.supported?(".jpg")
      assert MetadataStrip.supported?(".JPEG")
      assert MetadataStrip.supported?(".png")
      assert MetadataStrip.supported?(".webp")
    end

    test "refuses a container it cannot take apart, so the caller fails closed" do
      refute MetadataStrip.supported?(".heic")
      refute MetadataStrip.supported?(".tif")
      refute MetadataStrip.supported?("")
    end
  end

  test "an unknown container is refused rather than passed through" do
    assert MetadataStrip.strip_binary("not an image at all") == :unsupported
  end
end
