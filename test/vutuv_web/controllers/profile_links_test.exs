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
    # The thumb has to be on disk: since issue #1443 a row naming a file that
    # is not there renders the placeholder rather than a URL that would 404.
    write_thumb(url, "thumb-b0efec47a6e9.avif")

    html = conn |> get(~p"/#{user}") |> html_response(200)

    assert html =~ ~s(src="/screenshots/#{url.id}/thumb-b0efec47a6e9.avif")
  end

  test "a link whose stored capture is missing on disk falls back too", %{conn: conn} do
    user = insert_activated_user()
    url = insert(:url, user: user, screenshot: "b0efec47a6e9.webp")

    html = conn |> get(~p"/#{user}") |> html_response(200)

    assert html =~ ~s(src="/images/screenshot.png")
    refute html =~ "/screenshots/#{url.id}/"
  end

  # The test env's uploads prefix is the checkout itself, and `/screenshots` is
  # gitignored; the directory is named after a fresh UUID, so no two tests can
  # collide and this stays async.
  defp write_thumb(url, filename) do
    dir = Path.join(Vutuv.Uploads.uploads_dir_prefix(), "screenshots/#{url.id}")
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(20, 20, color: [1, 2, 3])
    {:ok, _} = Image.write(img, Path.join(dir, filename))
    on_exit(fn -> File.rm_rf(dir) end)
  end

  test "links whose capture is still on its way fall back to the placeholder image", %{conn: conn} do
    user = insert_activated_user()
    insert(:url, user: user, value: "https://example.com/page", screenshot: nil)

    html = conn |> get(~p"/#{user}") |> html_response(200)

    assert html =~ ~s(src="/images/screenshot.png")
  end

  test "a link this installation never captures names the site instead", %{conn: conn} do
    # "A screenshot has not been created yet" would be a promise that never
    # comes true for a blocklisted page (Vutuv.ScreenshotBlocklist), so the
    # tile carries the site's name and the card reads as finished.
    user = insert_activated_user()
    insert(:url, user: user, value: "https://www.heise.de/newsticker/x.html", screenshot: nil)

    html = conn |> get(~p"/#{user}") |> html_response(200)

    refute html =~ ~s(src="/images/screenshot.png")
    assert html =~ ~s(data-link-thumb="site")
    assert html =~ "www.heise.de…"
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
