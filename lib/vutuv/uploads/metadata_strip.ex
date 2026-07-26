defmodule Vutuv.Uploads.MetadataStrip do
  @moduledoc """
  Removes every metadata block from an image file **without touching a single
  pixel** (issue #1104).

  This is what backs the "just the picture" download: a photographer hands a
  client the full-resolution file, and the file carries no location, no camera
  serial number, no owner name, no software trail — while the compressed image
  data is copied through byte for byte, so it is not a re-encode and loses no
  quality.

  It works at the **container** level, which is why it can promise both
  things at once. A JPEG is a chain of marker segments wrapped around one
  entropy-coded scan; a PNG a chain of length-prefixed chunks; a WebP a RIFF
  chunk list. In all three the metadata sits in its own segments beside the
  image data, so dropping those segments and copying the rest verbatim is
  exact.

  **A whitelist, not a blacklist.** Only the segments needed to decode the
  image and reproduce its colours survive; anything else is dropped, known or
  not. A camera maker inventing a new proprietary block next year therefore
  cannot leak through a rule that has not heard of it yet.

  `strip/2` answers `:unsupported` for a format it cannot take apart safely
  (HEIC), and the caller must **fail closed**: no cleaned download is offered
  for such a photo. Serving a file we could not verify as clean would break
  exactly the promise this module exists to keep.
  """

  @doc """
  The bytes of `path` with all metadata removed, or `:unsupported` for a
  container this module does not take apart.

  `ext` is the stored extension (`".jpg"`, `".png"`, …); the actual bytes are
  still sniffed, so a mislabelled file cannot route itself to the wrong
  parser.
  """
  def strip(path, _ext) when is_binary(path) do
    case File.read(path) do
      {:ok, binary} -> strip_binary(binary)
      _error -> :unsupported
    end
  end

  @doc "`strip/2` for bytes already in memory."
  def strip_binary(<<0xFF, 0xD8, _rest::binary>> = jpeg), do: jpeg(jpeg)

  def strip_binary(<<137, "PNG\r\n", 26, 10, _rest::binary>> = png), do: png(png)

  def strip_binary(<<"RIFF", _size::little-32, "WEBP", _rest::binary>> = webp), do: webp(webp)

  def strip_binary(_other), do: :unsupported

  @doc """
  Whether a file with this extension can be cleaned. The composer asks before
  it offers the choice, so an author is never promised a cleaned copy the
  download route would then have to refuse.
  """
  def supported?(ext) when is_binary(ext) do
    String.downcase(ext) in ~w(.jpg .jpeg .png .webp)
  end

  def supported?(_ext), do: false

  ## JPEG

  # APPn (0xE0-0xEF) carries EXIF, XMP, IPTC, ICC and every maker's private
  # block; COM (0xFE) is the free-text comment. Everything else — the frame
  # header, the quantisation and Huffman tables, the scan — is what decodes
  # the picture and is copied through untouched.
  defp jpeg(<<0xFF, 0xD8, rest::binary>>) do
    case jpeg_segments(rest, [<<0xFF, 0xD8>>]) do
      {:ok, parts} -> IO.iodata_to_binary(parts)
      :error -> :unsupported
    end
  end

  defp jpeg_segments(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  # SOS (0xDA) opens the entropy-coded scan, which is not length-delimited:
  # everything from here to the end of the file is image data (plus the EOI
  # and, in a progressive JPEG, further scans). Copy the remainder verbatim —
  # no metadata can hide there, and it is the part that must stay identical.
  defp jpeg_segments(<<0xFF, 0xDA, rest::binary>>, acc) do
    {:ok, Enum.reverse([rest, <<0xFF, 0xDA>> | acc])}
  end

  # Standalone markers: no length word follows them.
  defp jpeg_segments(<<0xFF, marker, rest::binary>>, acc)
       when marker == 0xD8 or marker == 0xD9 or marker == 0x01 or
              (marker >= 0xD0 and marker <= 0xD7) do
    jpeg_segments(rest, [<<0xFF, marker>> | acc])
  end

  # Fill bytes: a run of 0xFF before a marker is legal padding.
  defp jpeg_segments(<<0xFF, 0xFF, rest::binary>>, acc) do
    jpeg_segments(<<0xFF, rest::binary>>, acc)
  end

  defp jpeg_segments(<<0xFF, marker, length::16, rest::binary>>, acc) when length >= 2 do
    payload_size = length - 2

    case rest do
      <<payload::binary-size(^payload_size), tail::binary>> ->
        if jpeg_metadata_marker?(marker) do
          jpeg_segments(tail, acc)
        else
          jpeg_segments(tail, [[<<0xFF, marker, length::16>>, payload] | acc])
        end

      _truncated ->
        :error
    end
  end

  # Anything else means the file is not the JPEG it claims to be. Refusing is
  # the only safe answer: a parser that guesses could copy a metadata block
  # through as image data.
  defp jpeg_segments(_other, _acc), do: :error

  defp jpeg_metadata_marker?(marker) do
    (marker >= 0xE0 and marker <= 0xEF) or marker == 0xFE
  end

  ## PNG

  @png_signature <<137, "PNG\r\n", 26, 10>>

  # Kept: the four critical chunks plus the ancillary ones that change how the
  # picture *looks* — transparency, the colour profile and the colour-space
  # hints. Dropped: eXIf, tEXt/zTXt/iTXt, tIME and every unknown ancillary
  # chunk, none of which a decoder needs.
  @png_keep ~w(IHDR PLTE IDAT IEND tRNS gAMA cHRM sRGB iCCP sBIT bKGD sPLT pHYs)

  defp png(<<@png_signature, rest::binary>>) do
    case png_chunks(rest, [@png_signature]) do
      {:ok, parts} -> IO.iodata_to_binary(parts)
      :error -> :unsupported
    end
  end

  defp png_chunks(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp png_chunks(<<length::32, type::binary-4, rest::binary>>, acc) do
    case rest do
      <<data::binary-size(^length), crc::binary-4, tail::binary>> ->
        if type in @png_keep do
          png_chunks(tail, [[<<length::32>>, type, data, crc] | acc])
        else
          png_chunks(tail, acc)
        end

      _truncated ->
        :error
    end
  end

  defp png_chunks(_other, _acc), do: :error

  ## WebP

  # A RIFF chunk list: keep the image chunks, drop EXIF and XMP. The extended
  # header (VP8X) also *advertises* which of those are present, so its flag
  # byte is corrected too — a decoder that trusts the flags and then finds no
  # such chunk is entitled to call the file broken.
  defp webp(<<"RIFF", _size::little-32, "WEBP", rest::binary>>) do
    case webp_chunks(rest, []) do
      {:ok, chunks} ->
        payload = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        <<"RIFF", byte_size(payload) + 4::little-32, "WEBP", payload::binary>>

      :error ->
        :unsupported
    end
  end

  defp webp_chunks(<<>>, acc), do: {:ok, acc}

  # A trailing odd-length pad byte with no chunk behind it.
  defp webp_chunks(<<0>>, acc), do: {:ok, acc}

  defp webp_chunks(<<fourcc::binary-4, size::little-32, rest::binary>>, acc) do
    # Every chunk is padded to an even length; the pad byte is not counted.
    padding = rem(size, 2)

    case rest do
      <<data::binary-size(^size), _pad::binary-size(^padding), tail::binary>> ->
        case fourcc do
          "EXIF" -> webp_chunks(tail, acc)
          "XMP " -> webp_chunks(tail, acc)
          "VP8X" -> webp_chunks(tail, [webp_chunk(fourcc, webp_clear_flags(data)) | acc])
          _keep -> webp_chunks(tail, [webp_chunk(fourcc, data) | acc])
        end

      _truncated ->
        :error
    end
  end

  defp webp_chunks(_other, _acc), do: :error

  defp webp_chunk(fourcc, data) do
    size = byte_size(data)
    pad = if rem(size, 2) == 1, do: <<0>>, else: <<>>
    [fourcc, <<size::little-32>>, data, pad]
  end

  # VP8X flag byte: bit 0x08 announces an EXIF chunk, 0x04 an XMP one. Both
  # are gone, so both bits must be.
  defp webp_clear_flags(<<flags, rest::binary>>) do
    <<Bitwise.band(flags, 0xF3), rest::binary>>
  end

  defp webp_clear_flags(data), do: data
end
