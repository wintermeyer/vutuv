defmodule Vutuv.BrowserFrame do
  @moduledoc """
  Wraps a captured page image in a browser window frame.

  Headless Chromium only renders the page itself, so to get the "whole
  browser" look we composite a chrome title bar on top: three traffic-light
  buttons on the left and a rounded address bar showing the URL. The page is
  stacked underneath at its original size, so the result is `chrome_height/0`
  pixels taller than the input.

  Rendering uses libvips via the `Image` package, the same dependency already
  used for avatars and screenshot thumbs.
  """

  @chrome_height 44
  @bar_color [223, 225, 229]
  @lights [[255, 95, 87], [254, 188, 46], [40, 200, 64]]
  @light_radius 6
  @light_y 22
  @first_light_x 18
  @light_spacing 18
  @pill_color [255, 255, 255]
  @pill_left 78
  @pill_right_margin 16
  @pill_top 11
  @pill_height 22
  @pill_radius 6
  @text_color [60, 64, 67]
  @text_font_size 15

  @doc "Height in pixels of the browser chrome bar added above the page."
  def chrome_height, do: @chrome_height

  @doc """
  Reads the page image at `page_path`, composites the browser frame with
  `url` shown in the address bar, and writes the result to `out_path`.

  Returns `{:ok, out_path}` or `{:error, reason}`.
  """
  def wrap(page_path, url, out_path) do
    with {:ok, page} <- Image.open(page_path),
         width = Image.width(page),
         {:ok, bar} <- build_bar(width, url),
         {:ok, canvas} <-
           Image.new(width, @chrome_height + Image.height(page), color: [255, 255, 255]),
         {:ok, canvas} <- Image.compose(canvas, bar, x: 0, y: 0),
         {:ok, canvas} <- Image.compose(canvas, page, x: 0, y: @chrome_height),
         # High quality: this framed image is the source the thumbnail
         # downsamples from, so keep it near-lossless (ignored for PNG output).
         {:ok, _} <- Image.write(canvas, out_path, quality: 92) do
      {:ok, out_path}
    end
  end

  defp build_bar(width, url) do
    with {:ok, bar} <- Image.new(width, @chrome_height, color: @bar_color),
         {:ok, bar} <- draw_lights(bar) do
      draw_address_bar(bar, width, url)
    end
  end

  defp draw_lights(bar) do
    @lights
    |> Enum.with_index()
    |> Enum.reduce({:ok, bar}, fn {color, i}, acc ->
      with {:ok, img} <- acc do
        Image.Draw.circle(img, @first_light_x + i * @light_spacing, @light_y, @light_radius,
          color: color,
          fill: true
        )
      end
    end)
  end

  defp draw_address_bar(bar, width, url) do
    pill_width = width - @pill_left - @pill_right_margin

    with true <- pill_width > 0,
         {:ok, pill} <- Image.new(pill_width, @pill_height, color: @pill_color),
         {:ok, pill} <- Image.rounded(pill, radius: @pill_radius),
         {:ok, bar} <- Image.compose(bar, pill, x: @pill_left, y: @pill_top) do
      compose_url(bar, url, pill_width)
    else
      false -> {:ok, bar}
      other -> other
    end
  end

  # The URL text sits inside the pill, left-padded and vertically centred.
  defp compose_url(bar, url, pill_width) do
    max_text_width = pill_width - 20

    case render_url(url, max_text_width) do
      {:ok, text} ->
        y = @pill_top + div(@pill_height - Image.height(text), 2)
        Image.compose(bar, text, x: @pill_left + 10, y: max(y, 0))

      # Text rendering is non-essential chrome; never let it sink a screenshot.
      _ ->
        {:ok, bar}
    end
  end

  defp render_url(url, max_width) when max_width > 0 do
    with {:ok, text} <-
           Image.Text.text(url, font_size: @text_font_size, text_fill_color: @text_color) do
      cond do
        Image.width(text) <= max_width -> {:ok, text}
        # Already as short as it gets; accept the overflow rather than loop.
        String.length(url) <= 1 -> {:ok, text}
        true -> render_url(truncate(url, max_width, Image.width(text)), max_width)
      end
    end
  end

  defp render_url(_url, _max_width), do: :skip

  # Estimate how many characters fit, drop the rest, and append an ellipsis.
  defp truncate(url, max_width, full_width) do
    keep = trunc(String.length(url) * max_width / full_width) - 1
    String.slice(url, 0, max(keep, 1)) <> "…"
  end
end
