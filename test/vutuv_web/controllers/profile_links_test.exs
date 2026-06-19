defmodule VutuvWeb.ProfileLinksTest do
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  # The Links section showcases the headless-Chromium page screenshots that
  # Vutuv.PageScreenshot already generates for every link: it lives in the
  # wide main column (not the right rail) and renders each link as a preview
  # card with its thumbnail.

  test "links render their screenshot thumbnails as preview cards", %{conn: conn} do
    user = insert_activated_user()
    url = insert(:url, user: user, screenshot: "b0efec47a6e9.webp")

    html = conn |> get(~p"/#{user}") |> html_response(200)

    assert html =~ ~s(src="/screenshots/#{url.id}/thumb-b0efec47a6e9.avif")
  end

  test "links without a screenshot fall back to the placeholder image", %{conn: conn} do
    user = insert_activated_user()
    insert(:url, user: user, screenshot: nil)

    html = conn |> get(~p"/#{user}") |> html_response(200)

    assert html =~ ~s(src="/images/screenshot.png")
  end

  test "the profile preview shows links in the owner's chosen order", %{conn: conn} do
    user = insert_activated_user()
    insert(:url, user: user, description: "Second", position: 2)
    insert(:url, user: user, description: "First", position: 1)

    html = conn |> get(~p"/#{user}") |> html_response(200)

    {first, _} = :binary.match(html, "First")
    {second, _} = :binary.match(html, "Second")
    assert first < second, "expected the position-1 link to render before position-2"
  end

  test "the links section sits in the main column, not the right rail", %{conn: conn} do
    user = insert_activated_user()
    insert(:url, user: user)

    html = conn |> get(~p"/#{user}") |> html_response(200)

    {links_pos, _} = :binary.match(html, ~s(id="profile-links"))
    {aside_pos, _} = :binary.match(html, "<aside")
    assert links_pos < aside_pos, "expected #profile-links before the <aside> right rail"
  end

  # "View All" is content navigation, not management chrome: it must only
  # appear when there really is more than the profile already shows (the
  # profile lists the latest 3). Management lives in the owner's card menu.
  describe "View All" do
    test "absent when every link is already on the page", %{conn: conn} do
      user = insert_activated_user()
      insert_list(2, :url, user: user)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      refute html =~ ~s(href="#{~p"/#{user}/links"}")
    end

    test "present when more links exist than are shown", %{conn: conn} do
      user = insert_activated_user()
      insert_list(5, :url, user: user)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ ~s(href="#{~p"/#{user}/links"}")
    end
  end
end
