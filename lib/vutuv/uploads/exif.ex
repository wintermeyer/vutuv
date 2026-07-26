defmodule Vutuv.Uploads.Exif do
  @moduledoc """
  Reads the **whitelisted** camera facts out of an uploaded photo (issue
  #1104): which camera and lens took it, at what focal length, aperture,
  shutter speed and ISO, and when.

  Three rules hold this feature honest:

  1. **A whitelist, never a blacklist.** `read/1` returns exactly the seven
     fields `Vutuv.Posts.PostImage` has columns for. Everything else a camera
     writes — maker notes, serial numbers, the owner's name, the software
     trail — is simply never looked at, so it cannot leak by omission when a
     new camera invents a new tag.

  2. **GPS coordinates are never parsed.** `has_gps?` answers only *whether*
     the file carried a location, which is what the composer needs to warn an
     author before they publish the byte-identical file. The latitude and
     longitude themselves are never read into the VM, never stored and never
     rendered.

  3. **It stays local.** libvips already carries the EXIF block in the image
     header, so this is a pure in-process parse: no lookup service, no
     outbound request, and an intranet installation behaves identically.

  The served AVIF versions stay metadata-stripped as before
  (`Vutuv.Uploads.Spec`); the camera panel renders from these DB columns, not
  from the delivered file.
  """

  alias Vix.Vips.Image, as: VipsImage

  # A GPS block shows up as libvips header fields named `exif-ifd<n>-GPS…`.
  # Which IFD number carries them differs between libvips builds, so the check
  # matches the tag *name* rather than one exact field — and it only ever asks
  # whether such a field exists. No value is read.
  @gps_marker "GPS"

  @empty %{
    camera: nil,
    lens: nil,
    focal_length: nil,
    aperture: nil,
    shutter: nil,
    iso: nil,
    taken_at: nil,
    has_gps: false
  }

  @doc """
  The whitelisted camera facts of the photo at `path`, as a map ready to be
  cast onto a `Vutuv.Posts.PostImage`.

  Always returns a map: a screenshot, an export that dropped its metadata or
  a file whose EXIF block is malformed simply yields all-`nil` fields, which
  the composer reports as "this file carries no camera information". Reading
  metadata must never be able to fail an upload.
  """
  def read(path) when is_binary(path) do
    case Image.open(path) do
      {:ok, image} -> read_image(image)
      _error -> @empty
    end
  end

  @doc """
  `read/1` for an already-opened image — the upload path, which has decoded
  the file once already and must not pay for a second decode.

  Pass the image **before** `Image.autorotate/1`: rotating rewrites the
  header, and on some builds drops the EXIF block with it.
  """
  def read_image(%VipsImage{} = image) do
    exif =
      case Image.exif(image) do
        {:ok, exif} when is_map(exif) -> flatten(exif)
        _error -> %{}
      end

    %{
      camera: camera(exif),
      lens: lens(exif),
      focal_length: focal_length(exif[:focal_length]),
      aperture: aperture(exif[:f_number]),
      shutter: shutter(exif[:exposure_time]),
      iso: iso(exif[:iso_speed_ratings]),
      taken_at: taken_at(exif[:datetime_original] || exif[:datetime_digitized]),
      has_gps: gps?(image)
    }
  end

  def read_image(_other), do: @empty

  @doc """
  Whether the file carries location data. The header field is only tested for
  presence — see the module note; nothing about *where* is ever read.
  """
  def gps?(%VipsImage{} = image) do
    case VipsImage.header_field_names(image) do
      {:ok, names} -> Enum.any?(names, &String.contains?(&1, @gps_marker))
      _error -> false
    end
  end

  def gps?(_other), do: false

  @doc """
  The camera facts as one line, e.g.
  `"Canon EOS R6 · RF 50mm F1.8 STM · 50 mm · f/1.8 · 1/200 s · ISO 400"`.

  `nil` when the photo carries nothing worth showing, which is the check the
  composer and the lightbox both branch on — so "is there camera info" is
  asked in exactly one place.
  """
  def summary(fields) do
    [
      fields[:camera],
      fields[:lens],
      fields[:focal_length] && "#{fields[:focal_length]} mm",
      fields[:aperture] && "f/#{fields[:aperture]}",
      fields[:shutter] && "#{fields[:shutter]} s",
      fields[:iso] && "ISO #{fields[:iso]}"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  # EXIF is two nested directories: the camera body writes make/model/orientation
  # into the main one, and the shot's own settings (aperture, shutter, ISO, lens)
  # into the ExifIFD sub-directory, which the library returns nested under
  # `:exif`. One flat map is what the field readers below want, and the outer
  # keys win — the sub-directory is the more specific but also the odder half.
  defp flatten(exif) do
    case exif[:exif] do
      nested when is_map(nested) -> Map.merge(nested, Map.delete(exif, :exif))
      _absent -> exif
    end
  end

  # "NIKON CORPORATION" + "NIKON D850" must read "NIKON D850", not
  # "NIKON CORPORATION NIKON D850": most makers repeat the brand in the model,
  # so the make is only prefixed when the model does not already carry it.
  defp camera(exif) do
    make = clean(exif[:make])
    model = clean(exif[:model])

    cond do
      is_nil(model) -> make
      is_nil(make) -> model
      String.starts_with?(String.downcase(model), String.downcase(first_word(make))) -> model
      true -> "#{make} #{model}"
    end
  end

  defp lens(exif) do
    clean(exif[:lens_model]) || clean(exif[:lens]) || clean(exif[:lens_make])
  end

  defp first_word(text), do: text |> String.split(" ", parts: 2) |> hd()

  # Trailing NULs and padding spaces are normal in EXIF ASCII fields; a field
  # that is blank after trimming carries no information and becomes nil.
  defp clean(value) when is_binary(value) do
    value
    |> String.replace(<<0>>, "")
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 120)
    end
  end

  defp clean(_value), do: nil

  # 50.0 reads as "50"; 24.5 keeps its decimal. Cameras report focal lengths
  # as rationals, so a prime lens would otherwise show up as "50.0 mm".
  defp focal_length(value) when is_number(value), do: trim_float(value)
  defp focal_length(_value), do: nil

  defp aperture(value) when is_number(value), do: trim_float(value)
  defp aperture(_value), do: nil

  # The library decodes a rational with numerator 1 to the string "1/200",
  # which is exactly the photographic notation — keep it. A whole or
  # fractional number of seconds (a long exposure) formats itself.
  defp shutter(value) when is_binary(value) do
    if Regex.match?(~r|^\d+/\d+$|, value), do: value
  end

  defp shutter(value) when is_number(value), do: trim_float(value)
  defp shutter(_value), do: nil

  # Some cameras report a list (ISO plus a secondary sensitivity); the first
  # entry is the one photographers mean.
  defp iso(value) when is_integer(value) and value > 0 and value < 10_000_000, do: value
  defp iso([value | _rest]), do: iso(value)
  defp iso(_value), do: nil

  defp taken_at(%NaiveDateTime{} = value), do: value
  defp taken_at(%DateTime{} = value), do: DateTime.to_naive(value)

  # EXIF stamps "2026:07:25 14:32:07" — colons in the date part, so it is not
  # ISO-8601 and needs its own parse. The library hands most builds an already
  # parsed struct (above); this is the fallback for the ones that do not, and
  # an unparseable stamp is simply dropped.
  defp taken_at(value) when is_binary(value) do
    with <<year::binary-4, ":", month::binary-2, ":", day::binary-2, " ", time::binary>> <-
           String.trim(value),
         {:ok, naive} <- NaiveDateTime.from_iso8601("#{year}-#{month}-#{day}T#{time}") do
      naive
    else
      _error -> nil
    end
  end

  defp taken_at(_value), do: nil

  defp trim_float(value) do
    rounded = Float.round(value / 1, 2)

    if rounded == Float.round(rounded, 0) do
      rounded |> trunc() |> Integer.to_string()
    else
      rounded |> Float.to_string() |> String.trim_trailing("0") |> String.trim_trailing(".")
    end
  end
end
