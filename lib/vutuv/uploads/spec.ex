defmodule Vutuv.Uploads.Spec do
  @moduledoc """
  The single source of truth for every **served** image version: resolution,
  fit/crop mode, output format and encoder quality, plus the one shared write
  pipeline all uploaders go through. A future format or compression change is
  an edit here followed by `Vutuv.Uploads.Regenerator.run/1`, which re-derives
  everything from the kept originals.

  Served versions are AVIF. Derived sizes are ~2x their largest CSS display
  size so they stay crisp on HiDPI screens (avatar slots per `VutuvWeb.UI`:
  xs 32 / sm 36 / md 48 / lg 96 px).

  The write pipeline is decode → `Image.autorotate` (`open_rotated/1`, once
  per upload) → resize per `fit` → `Vix.Vips.Operation.heifsave` with
  `keep: []`. EXIF autorotation must happen **before** metadata stripping —
  orientation is itself EXIF data, stripping first renders portrait phone
  photos sideways. `keep: []` is the only reliable strip: `Image.write(...,
  strip_metadata: true)` maps to the legacy `strip` saver param, which current
  libvips builds accept and silently ignore. heifsave defaults to HEVC, which
  the precompiled vix libheif cannot encode (patent licensing), so the AV1
  compression is set explicitly; `test/vutuv/uploads/spec_test.exs` fails
  loudly on a build that cannot encode AVIF.

  Originals are **not** versions: every uploader keeps the upload verbatim
  (format + metadata — the point of keeping it is re-deriving better formats
  later) in a private location that is never served.
  """

  alias Vix.Vips.Operation

  @served_ext ".avif"
  # Extensions a derived version may carry on disk from before the AVIF
  # switch; URL/path resolution falls back to these until the one-shot
  # regeneration has converted everything (then this fallback gets removed).
  @legacy_exts ~w(.webp .jpg .jpeg .png)

  @effort 4

  # `fit` shapes: {:crop, w, h, gravity} crops to exactly w×h;
  # {:box_down, s} fits within s×s; {:width_down, w} caps the width —
  # both *_down variants never upscale a smaller source.
  #
  # heifsave's Q scale is not WebP's: the former WebP Q80 is visually
  # ~AVIF Q58-63. Avatars get Q62 (blocking is most visible at tiny sizes
  # and the bytes are tiny anyway), photographic content Q58.
  @specs %{
    avatar: [
      %{name: :thumb, fit: {:crop, 96, 96, :center}, quality: 62},
      %{name: :medium, fit: {:crop, 192, 192, :center}, quality: 62}
    ],
    cover: [
      # Displayed ~768px wide on HiDPI; aspect ratio preserved, the display
      # crop is CSS object-cover, so tall photos are never baked away here.
      %{name: :wide, fit: {:width_down, 1600}, quality: 58}
    ],
    screenshot: [
      # 2x the 400x264 on-page display size; crop :high keeps the page top.
      %{name: :thumb, fit: {:crop, 800, 528, :high}, quality: 58}
    ],
    post_image: [
      # thumb: square feed-grid cell; feed: single-image feed width;
      # large: permalink/lightbox.
      %{name: :thumb, fit: {:crop, 320, 320, :center}, quality: 58},
      %{name: :feed, fit: {:box_down, 1200}, quality: 58},
      %{name: :large, fit: {:box_down, 1600}, quality: 58}
    ]
  }

  @doc "The extension every served version carries."
  def served_ext, do: @served_ext

  @doc "Extensions pre-AVIF derived files may still carry on disk."
  def legacy_exts, do: @legacy_exts

  @doc "The ordered version specs of an image type."
  def versions(type), do: Map.fetch!(@specs, type)

  @doc "A single version spec of an image type."
  def version(type, name) do
    type |> versions() |> Enum.find(&(&1.name == name)) ||
      raise ArgumentError, "unknown #{type} version #{inspect(name)}"
  end

  @doc """
  Decodes `path` and applies the EXIF orientation, returning
  `{:ok, %Vix.Vips.Image{}}` ready for `write_derived/3` (decode and rotate
  once, then derive all versions from it) or `{:error, reason}` when the file
  cannot be decoded.
  """
  # A generous ceiling — far above any real avatar/cover/post photo (all
  # downscaled to ≤1600px), far below the pixel-flood "decompression bombs"
  # that slip past the byte-size gate: a flat 30000×30000 PNG is ~2 MB on disk
  # but ~3.6 GB once decoded. The dimensions come from the header, so an
  # oversized image is rejected before autorotate/thumbnail pull its pixels.
  @max_megapixels 50

  def open_rotated(path) do
    with {:ok, image} <- Image.open(path),
         :ok <- within_pixel_budget(image),
         {:ok, {rotated, _flags}} <- Image.autorotate(image) do
      {:ok, rotated}
    end
  end

  defp within_pixel_budget(image) do
    if Image.width(image) * Image.height(image) > @max_megapixels * 1_000_000 do
      {:error, :too_large}
    else
      :ok
    end
  end

  @doc """
  Resizes the (already rotated) `image` per the version `spec` and writes it
  to `dest` as metadata-stripped AVIF. Returns `:ok` or `{:error, reason}`.
  """
  def write_derived(%{fit: fit, quality: quality}, image, dest) do
    with {:ok, resized} <- resize(image, fit) do
      save(resized, dest, quality)
    end
  end

  defp resize(image, {:crop, width, height, gravity}) do
    Image.thumbnail(image, "#{width}x#{height}", crop: gravity)
  end

  # resize: :down so a smaller upload keeps its native size instead of
  # being blurrily upscaled.
  defp resize(image, {:box_down, size}) do
    Image.thumbnail(image, "#{size}x#{size}", resize: :down)
  end

  defp resize(image, {:width_down, width}) do
    Image.thumbnail(image, "#{width}", resize: :down)
  end

  defp save(image, dest, quality) do
    case Operation.heifsave(image, dest,
           compression: :VIPS_FOREIGN_HEIF_COMPRESSION_AV1,
           Q: quality,
           effort: @effort,
           keep: []
         ) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
