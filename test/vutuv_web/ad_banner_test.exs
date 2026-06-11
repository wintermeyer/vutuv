defmodule VutuvWeb.AdBannerTest do
  @moduledoc """
  The ad banner between the top navigation and the content
  (`VutuvWeb.Plug.AdBanner` + the layout's `ad_banner` component): shown at
  most once per hour per session, clearly labeled as an ad, auto-hidden
  after two minutes by app.js (via the `data-ad-banner` hook), and replaced
  by the house ad (an ad for the ad system) on days nobody booked.
  """

  use VutuvWeb.ConnCase

  alias Vutuv.Ads

  @hour 3600

  describe "what the banner shows" do
    test "a day without a booking carries the house ad linking to /ads", %{conn: conn} do
      conn = get(conn, ~p"/community")
      html = html_response(conn, 200)

      assert html =~ "id=\"vutuv-ad\""
      assert html =~ "data-ad-banner"
      # The required, unmistakable ad label.
      assert html =~ ">Ad</span>"
      assert html =~ ~s(href="/ads")
    end

    test "on a booked day the ad's Markdown renders instead", %{conn: conn} do
      insert(:ad, day: Ads.today(), content: "**Acme** sucht [Leute](https://jobs.acme.example)")

      html = conn |> get(~p"/community") |> html_response(200)

      assert html =~ "id=\"vutuv-ad\""
      assert html =~ "<strong>Acme</strong>"
      assert html =~ ~s(href="https://jobs.acme.example")
      assert html =~ ">Ad</span>"
    end
  end

  describe "the hourly frequency cap" do
    test "the banner shows once, then not again within the hour", %{conn: conn} do
      conn = get(conn, ~p"/community")
      assert html_response(conn, 200) =~ "id=\"vutuv-ad\""

      conn = get(conn, ~p"/community")
      refute html_response(conn, 200) =~ "id=\"vutuv-ad\""
    end

    test "after an hour the banner shows again", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{ad_seen_at: System.system_time(:second) - @hour - 1})
        |> get(~p"/community")

      assert html_response(conn, 200) =~ "id=\"vutuv-ad\""
    end

    test "a fresh sighting within the hour stays suppressed", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{ad_seen_at: System.system_time(:second) - 60})
        |> get(~p"/community")

      refute html_response(conn, 200) =~ "id=\"vutuv-ad\""
    end

    test "a response without the banner does not burn the hourly slot", %{conn: conn} do
      # A 404 (or any page that never rendered the banner) must not count as
      # a sighting: the next regular page still shows the ad.
      conn = get(conn, "/this-slug-does-not-exist")
      assert conn.status == 404

      conn = get(conn, ~p"/community")
      assert html_response(conn, 200) =~ "id=\"vutuv-ad\""
    end
  end

  test "the booking pages themselves carry no banner", %{conn: conn} do
    refute conn |> get(~p"/ads") |> html_response(200) =~ "id=\"vutuv-ad\""
  end

  test "logged-in members get the banner too", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    assert conn |> get(~p"/community") |> html_response(200) =~ "id=\"vutuv-ad\""
  end
end
