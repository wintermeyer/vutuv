defmodule VutuvWeb.OgCard do
  @moduledoc """
  The default link-preview image (1200×630, the Open Graph recommended
  size): the white vutuv wordmark on the brand gradient. Pages without a
  better image point `og:image` here (see `VutuvWeb.OpenGraph`); served at
  `/og-card.png`.

  Generated once per node on first request and cached in `:persistent_term`.
  The wordmark comes from the vector logo (`priv/static/images/vutuv-logo.svg`,
  rasterized by the librsvg inside vix's bundled libvips) — deliberately no
  text rendering, which would depend on the host's fonts and make the card
  differ between dev and production. The gradient colors are the brand
  tokens from `assets/css/app.css` (brand-700 → brand-500, the auth-hero
  gradient).
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
        result = generate()
        :persistent_term.put({__MODULE__, :png}, result)
        result

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
    # A host whose libvips cannot rasterize the SVG must degrade to "no
    # default image", never to a 500 on every page render.
    _ -> :error
  end

  # Rasterize the SVG large (the wordmark sits small inside an A4-shaped
  # page), find its bounding box against white, crop it out and recolor it
  # white through its own alpha channel.
  defp white_wordmark do
    path = Path.join(Application.app_dir(:vutuv, "priv"), "static/images/vutuv-logo.svg")

    with {:ok, page} <- Image.thumbnail(path, 2400),
         {:ok, on_white} <- Image.flatten(page, background_color: :white),
         {:ok, {left, top, w, h}} <-
           Vix.Vips.Operation.find_trim(on_white,
             background: [255.0, 255.0, 255.0],
             threshold: 10
           ),
         {:ok, wordmark} <- Image.crop(page, left, top, w, h),
         {_rgb, alpha} <- Image.split_alpha(wordmark),
         {:ok, white} <- Image.new(w, h, color: :white),
         {:ok, logo} <- Image.add_alpha(white, alpha) do
      Image.thumbnail(logo, @logo_width)
    else
      _ -> :error
    end
  end
end
