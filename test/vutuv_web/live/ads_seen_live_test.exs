defmodule VutuvWeb.AdsSeenLiveTest do
  @moduledoc """
  The member's list of the ads vutuv showed them, at `/system/ads/seen`
  (`VutuvWeb.AdsSeenLive`): newest sighting first, with when and how often,
  searchable and paged. The card's "Ad" label leads there for a member and to
  the `/system/ads` offer page for a visitor, who has no history to look at.
  """

  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Ads

  @path "/system/ads/seen"

  test "a visitor is sent to the login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, @path)
  end

  test "a member who saw nothing is told so", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    {:ok, _view, html} = live(conn, @path)

    assert html =~ "You have not seen an ad in the last 90 days."
    assert html =~ ~s(href="/system/ads")
  end

  test "lists the ads the member saw, newest first, with how often", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    older = insert_ad_sighting(user, ~D[2026-09-10], title: "Older ad")
    newer = insert_ad_sighting(user, ~D[2026-09-12], title: "Newer ad", times_seen: 3)
    insert_ad_sighting(insert_activated_user(), ~D[2026-09-11], title: "Somebody else's ad")

    {:ok, view, html} = live(conn, @path)

    assert articles(view) == ["sightings-#{newer.id}", "sightings-#{older.id}"]
    assert view |> element("#sightings-#{newer.id}") |> render() =~ "3 times"
    assert view |> element("#sightings-#{older.id}") |> render() =~ "once"
    refute html =~ "Somebody else"
    assert html =~ "2 ads"
  end

  test "the search narrows the list, and says when nothing matches", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    insert_ad_sighting(user, ~D[2026-09-10], title: "Wann sind Ferien 2027?")
    insert_ad_sighting(user, ~D[2026-09-11], title: "Backend-Entwicklung in Mainz")

    {:ok, view, _html} = live(conn, @path)

    html = view |> form("#ads-seen-search", q: "ferien") |> render_change()
    assert html =~ "Ferien"
    refute html =~ "Mainz"
    assert html =~ "1 match"

    html = view |> form("#ads-seen-search", q: "Kochkurs") |> render_change()
    assert html =~ "No ad you have seen matches “Kochkurs”."
  end

  test "more rows come in pages", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    for n <- 1..21,
        do: insert_ad_sighting(user, Date.add(~D[2026-08-01], n), title: "Ad #{n}")

    {:ok, view, _html} = live(conn, @path)
    assert length(articles(view)) == 20

    view |> element("#load-more") |> render_click()

    assert length(articles(view)) == 21
    refute has_element?(view, "#load-more")
  end

  test "the German page reads German", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    insert_ad_sighting(user, Ads.today(), title: "Acme", times_seen: 2)

    conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de")
    {:ok, _view, html} = live(conn, @path)

    assert html =~ "Gesehene Anzeigen"
    assert html =~ "2-mal"
    assert html =~ "Zuletzt gesehen"
  end

  describe "the card's label" do
    test "leads a member to their seen ads", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/feed") |> html_response(200)

      assert html =~ ~r{<a[^>]*href="/system/ads/seen"[^>]*>\s*Ad\s*</a>}
    end

    test "leads a visitor to the offer page", %{conn: conn} do
      html = conn |> get(~p"/#{insert_activated_user()}") |> html_response(200)

      assert html =~ ~r{<a[^>]*href="/system/ads"[^>]*>\s*Ad\s*</a>}
      refute html =~ ~s(href="/system/ads/seen")
    end
  end

  # The ids of the listed entries, in page order.
  defp articles(view) do
    view |> render() |> elements("#ads-seen article") |> Enum.map(&attribute(&1, "id"))
  end
end
