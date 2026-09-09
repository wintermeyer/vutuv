defmodule VutuvWeb.OgImageTest do
  @moduledoc """
  The generated link-preview cards (`VutuvWeb.OgImage`): both shapes come out
  1200×630 whatever the data holds — no picture, markup in a name, a body
  longer than the card, nothing but emoji — because a card that fails is a
  page without a picture on every platform.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.OgImage

  defp size({:ok, png}) do
    {:ok, img} = Image.open(png)
    {Image.width(img), Image.height(img)}
  end

  defp jpeg do
    {:ok, img} = Image.new(512, 512, color: [200, 90, 40])
    {:ok, bytes} = Image.write(img, :memory, suffix: ".jpg")
    bytes
  end

  test "the profile card, with and without a picture" do
    data = %{
      name: "Greta Tester",
      headline: "Developer @ Acme Corp",
      tags: ["Elixir", "Phoenix", "open source", "PostgreSQL", "Rust", "Kubernetes", "Go"],
      meta: "12 followers · Member since 2016",
      footer: "vutuv.de/greta"
    }

    assert size(OgImage.profile_png(Map.put(data, :avatar, jpeg()))) == {1200, 630}
    assert size(OgImage.profile_png(data)) == {1200, 630}
  end

  test "the post card, short and far too long" do
    base = %{
      name: "Paula Post",
      avatar: jpeg(),
      meta: "September 9, 2026",
      footer: "vutuv.de/paula"
    }

    assert size(OgImage.post_png(Map.put(base, :text, "Two words."))) == {1200, 630}

    long = Enum.map_join(1..600, " ", &"word#{&1}")
    assert size(OgImage.post_png(Map.put(base, :text, long))) == {1200, 630}
  end

  test "the square card, short and far too long" do
    base = %{name: "Paula Post", avatar: jpeg()}

    assert size(OgImage.square_png(Map.put(base, :text, "Two words."))) == {1200, 1200}

    long = Enum.map_join(1..600, " ", &"word#{&1}")
    assert size(OgImage.square_png(Map.put(base, :text, long))) == {1200, 1200}
  end

  test "markup in the words is drawn as text, not read as Pango markup" do
    data = %{
      name: "<b>Bold</b> & Co",
      headline: "<span foreground=\"red\">x</span>",
      text: "a & b < c"
    }

    assert size(OgImage.post_png(data)) == {1200, 630}
    assert size(OgImage.profile_png(data)) == {1200, 630}
    assert size(OgImage.square_png(data)) == {1200, 1200}
  end

  test "a body of nothing but emoji, and no body at all, still make a card" do
    assert size(OgImage.post_png(%{name: "Emoji", text: "🎉🎉 💪 🇪🇺"})) == {1200, 630}
    assert size(OgImage.post_png(%{name: "Silent", text: nil})) == {1200, 630}
    assert size(OgImage.profile_png(%{name: "Only a name"})) == {1200, 630}
    assert size(OgImage.square_png(%{name: "Silent", text: "🎉"})) == {1200, 1200}
  end

  test "a single tag wider than the column leaves no empty pill row" do
    wide = %{name: "Wide", tags: [String.duplicate("tag", 60)]}
    narrow = %{name: "Wide", tags: ["ok"]}

    assert size(OgImage.profile_png(wide)) == {1200, 630}
    assert size(OgImage.profile_png(narrow)) == {1200, 630}
  end
end
