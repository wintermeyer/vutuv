defmodule Vutuv.Blurhash do
  @moduledoc """
  Decodes a BlurHash string into a small blurred picture (issue #1914).

  A BlurHash is ~30 characters that a publishing server computes from a picture
  and ships beside it: a handful of cosine coefficients, so what comes back out
  is the picture's colour arrangement and nothing an eye could identify. Every
  Mastodon attachment carries one — pictures and clips alike, and crucially
  **also the three quarters of clips that carry no cover** (`icon`), which is
  why this exists here at all. Without it those clips draw as a black box.

  ## Why decoding it here is safe to show

  `Vutuv.Moderation.Pixelation` writes a stand-in of 64 averaged cells for a
  picture whose bytes we hold but whose verdict is not in. A BlurHash carries
  far less than that — at most 9×9 coefficients, in practice 4×3 — so it can
  never resolve a face, a licence plate or a caption. It stands in for a
  picture we do **not** hold, which is the one case that had nothing at all.

  What it is not: a substitute for the AI gate. A blurred poster over a clip
  says what colours are in it, not that anybody looked at it. The clip behind
  it still streams unjudged from the instance that published it — see
  `docs/architecture/fediverse.md`.

  ## The format

  Base83, and every field is positional (`decode/1` refuses anything else):

    * char 0 — the component counts, `x = rem(n, 9) + 1`, `y = div(n, 9) + 1`
    * char 1 — the quantised maximum AC value
    * chars 2..5 — the DC term, the average colour as packed sRGB
    * two chars per remaining component, each packing three 19-step values

  Colours travel in **linear** light, so the sRGB transfer function is applied
  on the way in and its inverse on the way out; skipping either is what turns a
  correct decoder into one that is merely plausible and uniformly too dark.
  """

  alias Vix.Vips.Image, as: Vips

  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"

  @base83 @alphabet |> Enum.with_index() |> Map.new()

  # A hash is at most 9×9 components, so 4 + 2*81 = 166 characters. Anything
  # longer is not one, and the string comes from a server we do not control.
  @max_length 166

  @doc """
  Decodes `hash` into `{:ok, {width, height, rgb_binary}}` — one byte per
  channel, row-major — or `:error` for anything that is not a BlurHash.

  `width` and `height` are what you ask to render at, and small is the point:
  the coefficients hold no more than a handful of cells, so asking for 32×32
  costs the same information as asking for 320×320 and a thirtieth of the work.
  Both are capped at `64`.

  Never raises. The string arrives inside a stranger's ActivityPub attachment,
  so every malformed shape has to answer `:error` rather than take an inbox
  delivery down with it.
  """
  def decode(hash, width \\ 32, height \\ 32)

  def decode(hash, width, height)
      when is_binary(hash) and width in 1..64 and height in 1..64 do
    with true <- byte_size(hash) in 6..@max_length,
         {:ok, chars} <- base83_values(hash),
         {:ok, components} <- components(chars) do
      {:ok, {width, height, render(components, width, height)}}
    else
      _ -> :error
    end
  end

  def decode(_hash, _width, _height), do: :error

  defp base83_values(hash) do
    hash
    |> String.to_charlist()
    |> Enum.reduce_while({:ok, []}, fn char, {:ok, acc} ->
      case Map.fetch(@base83, char) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  # The size flag and the length have to agree, or the string is not a hash of
  # the size it claims — the one structural check the format allows.
  defp components([size_flag, quantised_max | rest]) do
    x = rem(size_flag, 9) + 1
    y = div(size_flag, 9) + 1

    if length(rest) == 4 + 2 * (x * y - 1) do
      {dc_chars, ac_chars} = Enum.split(rest, 4)
      max_value = (quantised_max + 1) / 166

      colors =
        [decode_dc(dc_chars) | Enum.map(Enum.chunk_every(ac_chars, 2), &decode_ac(&1, max_value))]

      {:ok, {x, y, colors}}
    else
      :error
    end
  end

  defp components(_chars), do: :error

  defp decode_dc(chars) do
    value = Enum.reduce(chars, 0, &(&2 * 83 + &1))

    {srgb_to_linear(Bitwise.bsr(value, 16)),
     srgb_to_linear(Bitwise.band(Bitwise.bsr(value, 8), 255)),
     srgb_to_linear(Bitwise.band(value, 255))}
  end

  defp decode_ac(chars, max_value) do
    value = Enum.reduce(chars, 0, &(&2 * 83 + &1))

    {ac_channel(div(value, 19 * 19), max_value), ac_channel(rem(div(value, 19), 19), max_value),
     ac_channel(rem(value, 19), max_value)}
  end

  defp ac_channel(quantised, max_value) do
    normalised = (quantised - 9) / 9
    sign_pow(normalised, 2.0) * max_value
  end

  defp sign_pow(value, exponent) do
    magnitude = :math.pow(abs(value), exponent)
    if value < 0, do: -magnitude, else: magnitude
  end

  defp render({x_count, _y_count, colors}, width, height) do
    # The cosine basis depends only on the pixel and the component index, and
    # every pixel in a row shares the x half — but at 32×32 over 12 components
    # the whole render is ~12k multiplications, so it is written for reading
    # rather than pre-computed into tables nobody can check.
    indexed = Enum.with_index(colors)

    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
      {r, g, b} =
        Enum.reduce(indexed, {0.0, 0.0, 0.0}, fn {{cr, cg, cb}, index}, {ar, ag, ab} ->
          i = rem(index, x_count)
          j = div(index, x_count)

          basis =
            :math.cos(:math.pi() * x * i / width) * :math.cos(:math.pi() * y * j / height)

          {ar + cr * basis, ag + cg * basis, ab + cb * basis}
        end)

      <<linear_to_srgb(r), linear_to_srgb(g), linear_to_srgb(b)>>
    end
  end

  defp srgb_to_linear(value) do
    v = value / 255

    if v <= 0.04045,
      do: v / 12.92,
      else: :math.pow((v + 0.055) / 1.055, 2.4)
  end

  defp linear_to_srgb(value) do
    v = max(0.0, min(1.0, value))

    if v <= 0.0031308,
      do: round(v * 12.92 * 255 + 0.5),
      else: round((1.055 * :math.pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
  end

  @doc """
  The hash's average colour as `{r, g, b}` in sRGB, or `:error`.

  This is the DC term alone — the one value a BlurHash states outright rather
  than reconstructs — which makes it the thing to check a decoder against: the
  average colour of the real picture is measurable independently.
  """
  def average_color(hash) when is_binary(hash) do
    # Deliberately NOT `decode(hash, 1, 1)`: at a width of one, `cos(pi*0*i/1)`
    # is 1 for every component, so a one-pixel render sums the AC terms in at
    # full strength instead of dropping them. The DC term has to be read on its
    # own.
    with true <- byte_size(hash) >= 6,
         {:ok, [_size, _max | rest]} <- base83_values(hash),
         {dc_chars, _ac} <- Enum.split(rest, 4),
         true <- length(dc_chars) == 4 do
      {r, g, b} = decode_dc(dc_chars)
      {:ok, {linear_to_srgb(r), linear_to_srgb(g), linear_to_srgb(b)}}
    else
      _ -> :error
    end
  end

  def average_color(_hash), do: :error

  # 16×16 carries more than a hash holds — 4×3 components is the common shape,
  # so eight samples across already clears Nyquist — and it is what the size
  # measurement picks: 1,348 bytes of base64 against 3,992 at 32×32, for a
  # picture the browser scales up and blurs anyway. Both ends of that were
  # measured rather than guessed.
  @render_size 16

  @doc """
  The hash as a `data:` URI ready for an `<img src>` or a `<video poster>`, or
  `nil` for anything that is not a BlurHash.

  **A data URI rather than a stored file**, which is the opposite of what
  `Vutuv.Moderation.Pixelation` does for a picture we hold, and deliberately:
  serving a stored remote picture goes through `VutuvWeb.RemoteMediaController`,
  which re-checks the AI gate's verdict per request — and a coverless clip has
  no verdict to check, so it would need a second, unauthorised route to a tree
  of files with their own deletion path. The CSP already permits `img-src
  data:`, and at 1,348 bytes this costs less than the round trip would.

  Rendered per call, at ~25k reductions. That is nothing beside the ~1.4 KB it
  produces, and it only ever runs for a clip whose attachment named no cover.
  If a page ever holds enough of those to matter, the fix is a column holding
  this string, not a cache.
  """
  def data_uri(hash, aspect \\ nil)

  def data_uri(hash, aspect) when is_binary(hash) do
    {width, height} = render_size(aspect)

    with {:ok, {w, h, rgb}} <- decode(hash, width, height),
         {:ok, image} <- Vips.new_from_binary(rgb, w, h, 3, :VIPS_FORMAT_UCHAR),
         {:ok, png} <- Vips.write_to_buffer(image, ".png") do
      "data:image/png;base64," <> Base.encode64(png)
    else
      _ -> nil
    end
  end

  def data_uri(_hash, _aspect), do: nil

  # A poster is drawn in the CLIP's shape, not in a square. A `<video>` fits its
  # poster with the equivalent of `object-fit: contain`, so a square stand-in
  # under a 9:16 phone clip is letterboxed by black bands top and bottom —
  # which is the black box this was meant to remove, just smaller (seen in the
  # browser, which is the only place it shows).
  #
  # The long edge takes `@render_size` and the short one follows, floored at 4:
  # a hash holds at most 9 components on an axis, and a 16×4 render of a
  # panorama still carries every one of them.
  defp render_size({w, h}) when is_integer(w) and is_integer(h) and w > 0 and h > 0 do
    if w >= h do
      {@render_size, max(4, round(@render_size * h / w))}
    else
      {max(4, round(@render_size * w / h)), @render_size}
    end
  end

  defp render_size(_aspect), do: {@render_size, @render_size}
end
