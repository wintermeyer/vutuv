defmodule VutuvWeb.OgCard do
  @moduledoc """
  The default link-preview image (1200×630, the Open Graph recommended
  size): the white vutuv wordmark on the brand gradient. Pages without a
  better image point `og:image` here (see `VutuvWeb.OpenGraph`); served at
  `/og-card.png`.

  Generated once per node on first request and cached in `:persistent_term`.

  The wordmark is the pre-rasterized white logo
  (`priv/static/images/vutuv-wordmark-white.png`): white letters on a
  transparent background, tightly cropped. It is composed onto the gradient
  with only the PNG loader, which every libvips build ships, so the card
  renders identically across dev, test, CI and production. We deliberately do
  **not** rasterize the SVG at runtime: that needs the librsvg loader, which is
  only present when libvips can find it on the dynamic-library path, so it made
  the card succeed in the dev server yet fail under `mix test` on the same
  machine (issue #802). There is also no text rendering, which would depend on
  the host's fonts. The gradient colors are the brand tokens from
  `assets/css/app.css` (brand-700 → brand-500, the auth-hero gradient).

  To regenerate the wordmark PNG after the logo changes, rasterize the vector
  source (`priv/static/images/vutuv-logo.svg`) on a host whose libvips has the
  SVG loader and recolor it white through its own alpha:

      src = Path.join(Application.app_dir(:vutuv, "priv"), "static/images/vutuv-logo.svg")
      out = Path.join(Application.app_dir(:vutuv, "priv"), "static/images/vutuv-wordmark-white.png")
      {:ok, page} = Image.thumbnail(src, 2400)
      {:ok, on_white} = Image.flatten(page, background_color: :white)
      {:ok, {l, t, w, h}} = Vix.Vips.Operation.find_trim(on_white, background: [255.0, 255.0, 255.0], threshold: 10)
      {:ok, wordmark} = Image.crop(page, l, t, w, h)
      {_rgb, alpha} = Image.split_alpha(wordmark)
      {:ok, white} = Image.new(w, h, color: :white)
      {:ok, logo} = Image.add_alpha(white, alpha)
      Image.write(logo, out)
  """

  @width 1200
  @height 630
  @logo_width 560
  @brand_700 "#1e40af"
  @brand_500 "#2563eb"

  def width, do: @width
  def height, do: @height

  @doc "The card as PNG bytes, generated on first call; `:error` when generation fails."
  def png do
    case :persistent_term.get({__MODULE__, :png}, nil) do
      nil ->
        case generate() do
          {:ok, _png} = ok ->
            :persistent_term.put({__MODULE__, :png}, ok)
            ok

          error ->
            # Don't cache a transient failure (a libvips hiccup, or a boot-time
            # race before the wordmark asset is in place): leaving the key unset
            # lets the next request retry, instead of breaking og:image
            # node-wide until a restart.
            error
        end

      result ->
        result
    end
  end

  defp generate do
    with {:ok, logo} <- white_wordmark(),
         {:ok, bg} <-
           Image.linear_gradient(@width, @height,
             start_color: @brand_700,
             finish_color: @brand_500
           ),
         {:ok, card} <- Image.compose(bg, logo, x: :center, y: :center),
         {:ok, card} <- Image.flatten(card),
         {:ok, png} <- Image.write(card, :memory, suffix: ".png") do
      {:ok, png}
    else
      _ -> :error
    end
  rescue
    # Any libvips failure must degrade to "no default image", never to a 500
    # on every page render.
    _ -> :error
  end

  # Load the pre-rasterized white wordmark (white letters on transparent,
  # tightly cropped) and size it for the card. Only the PNG loader is used, so
  # this never depends on the librsvg loader being on the libvips path.
  defp white_wordmark do
    path =
      Path.join(Application.app_dir(:vutuv, "priv"), "static/images/vutuv-wordmark-white.png")

    Image.thumbnail(path, @logo_width)
  end
end
