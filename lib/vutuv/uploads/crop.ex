defmodule Vutuv.Uploads.Crop do
  @moduledoc """
  The user-chosen crop rectangle applied to an upload before it is resized
  into served versions.

  A crop is four fractions of the **EXIF-rotated** original — `{x, y, w, h}`
  in `0..1`, `x`/`y` the top-left corner, `w`/`h` the size — produced by the
  in-browser crop modal (`assets/js/image_crop.js`) and persisted per image
  (`users.avatar_crop` / `users.cover_crop`) so `Vutuv.Uploads.Regenerator`
  can re-apply it when it re-derives the served versions from the kept
  original (without persistence, the next format/quality regen would silently
  un-crop everyone).

  On the wire and in the DB a crop is the compact string `"x,y,w,h"`; `nil` or
  an unparseable value means "no crop" — the centered behavior from before the
  crop UI — and is never an error: a bad crop param must not fail an upload.

  Both sides agree on the **rotated** coordinate space. The browser reads
  pixels with `createImageBitmap(file, {imageOrientation: "from-image"})` and
  the server crops *after* `Vutuv.Uploads.Spec.open_rotated/1` autorotates, so
  the fractions line up regardless of the source's EXIF orientation.
  """

  @typedoc "A crop rectangle as `{x, y, w, h}` fractions in `0..1`."
  @type t :: {float(), float(), float(), float()}

  @doc """
  Parses a stored/submitted `"x,y,w,h"` string into `{x, y, w, h}` fractions,
  clamped to a valid in-bounds rectangle, or `nil` when the value is absent,
  malformed or degenerate (zero width/height, or a full-frame crop that would
  be a no-op).
  """
  @spec parse(String.t() | nil) :: t() | nil
  def parse(nil), do: nil

  def parse(value) when is_binary(value) do
    with [x, y, w, h] <- String.split(value, ","),
         {:ok, x} <- fraction(x),
         {:ok, y} <- fraction(y),
         {:ok, w} <- fraction(w),
         {:ok, h} <- fraction(h),
         {x, y, w, h} <- clamp_box(x, y, w, h),
         true <- meaningful?(x, y, w, h) do
      {x, y, w, h}
    else
      _ -> nil
    end
  end

  def parse(_), do: nil

  @doc """
  Validates and re-serialises a submitted crop string to its canonical
  `"x,y,w,h"` form, or `nil` when there is no meaningful crop. This is the
  value persisted in the DB column.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(value) do
    case parse(value) do
      nil -> nil
      {x, y, w, h} -> Enum.map_join([x, y, w, h], ",", &dump_fraction/1)
    end
  end

  @doc """
  Crops the (already EXIF-rotated) `image` to `crop`, or returns it unchanged
  when `crop` is `nil`. Resolves the fractions to clamped integer pixels so
  independent per-edge rounding can never push the box past the image bounds.
  """
  @spec apply_to(Vix.Vips.Image.t(), t() | nil) ::
          {:ok, Vix.Vips.Image.t()} | {:error, term()}
  def apply_to(image, nil), do: {:ok, image}

  def apply_to(image, {x, y, w, h}) do
    iw = Image.width(image)
    ih = Image.height(image)

    left = clamp(round(x * iw), 0, iw - 1)
    top = clamp(round(y * ih), 0, ih - 1)
    width = clamp(round(w * iw), 1, iw - left)
    height = clamp(round(h * ih), 1, ih - top)

    Image.crop(image, left, top, width, height)
  end

  defp fraction(str) do
    case Float.parse(String.trim(str)) do
      {f, ""} when f >= 0.0 and f <= 1.0 -> {:ok, f}
      _ -> :error
    end
  end

  # Trim the box so x+w and y+h never exceed 1.0 (the corner already sits in
  # 0..1, so the size is what can overrun).
  defp clamp_box(x, y, w, h), do: {x, y, min(w, 1.0 - x), min(h, 1.0 - y)}

  # A crop covering (almost) the whole frame is a no-op: treat it as none so we
  # neither pay the crop op nor persist a meaningless rectangle.
  defp meaningful?(x, y, w, h) do
    w > 0.0 and h > 0.0 and not (x <= 0.0 and y <= 0.0 and w >= 0.999 and h >= 0.999)
  end

  defp dump_fraction(f), do: :erlang.float_to_binary(f * 1.0, decimals: 4)

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end
