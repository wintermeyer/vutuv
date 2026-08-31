defmodule VutuvWeb.IconSpriteTest do
  @moduledoc """
  The glyphs a timeline repeats are defined once and referenced with `<use>`.

  Measured on production (2026-08-31), one `/feed` document carried 237 inline
  `<path d="…">` for **six** distinct shapes — 41 KB of its 673 KB. It is a
  parse-and-memory saving rather than a download one (zstd compresses that
  repetition away on the wire), which is why it is worth doing for the phone
  building the DOM.

  A broken `<use>` shows **nothing** and raises nothing, so the two halves are
  asserted together: the sprite has to be on the page, and the cards have to
  point at it rather than carrying their own copy of the path.
  """
  use VutuvWeb.ConnCase

  import Vutuv.PostsHelpers

  @glyphs ~w(glyph-heart glyph-reply glyph-repost glyph-bookmark)

  # The heart's own path data. If a card still carries this, the reference did
  # not replace it and the page is paying for both.
  @heart_path "M21 8.25c0-2.485-2.099-4.5-4.688-4.5"

  describe "the page defines each repeated glyph once" do
    test "the sprite ships with every glyph the action bar asks for", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      create_post!(user, %{body: "Etwas zu lesen."})

      html = conn |> get(~p"/feed") |> html_response(200)

      for glyph <- @glyphs do
        assert html =~ ~s(id="#{glyph}"), "the sprite must define #{glyph}"
        assert html =~ ~s(href="##{glyph}"), "something must reference #{glyph}"
      end
    end

    test "a card references the heart rather than repeating its path", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      for i <- 1..3, do: create_post!(user, %{body: "Beitrag #{i}"})

      html = conn |> get(~p"/feed") |> html_response(200)

      # Once in the sprite, nowhere else — three cards would otherwise carry
      # three more copies.
      assert html |> String.split(@heart_path) |> length() == 2,
             "the heart path belongs in the sprite only"

      # …and every card still asks for it.
      hearts = html |> String.split(~s(href="#glyph-heart")) |> length()
      assert hearts >= 4, "each of the three cards must reference the heart, got #{hearts - 1}"
    end
  end

  describe "the sprite is inert" do
    test "it is hidden and announces nothing", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/feed") |> html_response(200)

      [sprite | _] = String.split(html, ~s(id="glyph-repost"))
      opening = sprite |> String.split("<svg") |> List.last()

      assert opening =~ ~s(aria-hidden="true"), "a definitions block must not be announced"
      assert opening =~ ~s(width="0"), "and must not take layout"
    end
  end
end
