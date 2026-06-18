defmodule VutuvWeb.OgCardTest do
  @moduledoc """
  The default Open Graph brand card (`/og-card.png`): a 1200×630 PNG of the
  white vutuv wordmark on the brand gradient, used as the `og:image` fallback.

  These tests pin the fix for issue #802: card generation must **not** depend
  on libvips being able to rasterize an SVG (the librsvg loader is only present
  when libvips can find it on the dynamic-library path, so the card succeeded in
  the dev server yet failed under `mix test` on the same machine). The wordmark
  now ships pre-rasterized as a PNG, which every libvips build can load, so the
  card generates on every host.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.OgCard

  @png_magic <<137, ?P, ?N, ?G, ?\r, ?\n, 26, ?\n>>

  test "the wordmark asset is a pre-rasterized PNG, not an SVG" do
    # The guard against regressing to a runtime SVG rasterization: the asset the
    # card composes must be a PNG (always loadable) and must exist on disk.
    path = Path.join(Application.app_dir(:vutuv, "priv"), "static/images/vutuv-wordmark-white.png")
    assert File.exists?(path), "expected the pre-rasterized wordmark at #{path}"
    assert <<@png_magic, _rest::binary>> = File.read!(path)
  end

  test "png/0 generates a 1200×630 PNG on this host" do
    assert {:ok, png} = OgCard.png()
    assert <<@png_magic, _rest::binary>> = png

    assert {:ok, image} = Image.from_binary(png)
    assert Image.width(image) == OgCard.width()
    assert Image.height(image) == OgCard.height()
  end
end
