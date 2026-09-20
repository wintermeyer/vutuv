defmodule VutuvWeb.AdServingTest do
  @moduledoc """
  The daily text ad on the two pages that carry it, a profile and the feed:
  at the top of the rail on a desktop and as a card near the top on a phone.
  The request decides (`VutuvWeb.AdServing`), the LiveView shows what it was
  handed (`VutuvWeb.Live.AdSlot`). A member's rules live on the server: no ad
  at all in the first two weeks after signing up, then at most one an hour, and
  none for the rest of the day once the ✕ was pressed. A visitor without an
  account sees the ad on every page, and nothing about them is stored, neither
  on the server nor in a cookie.
  Only a profile carries the ad for a visitor; the feed needs an account.

  Every member here is `established_member/1`: a fresh `create_and_login_user/1`
  would see no ad for any of these tests.
  """

  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Accounts.User
  alias Vutuv.Ads
  alias Vutuv.Ads.Sighting
  alias VutuvWeb.AdServing

  @rail ~s(id="ad-slot-rail")
  @inline ~s(id="ad-slot-inline")
  # The house ad's own words: its /system/ads link is no tell, the footer links there
  # too while the system is on.
  @house "This spot is free today."

  # A member whose profile the test's anonymous conn opens.
  defp profile_owner, do: insert_activated_user()

  # A signed-in member the ad system is willing to serve: registration is far
  # enough back that the frequency rules are what decides.
  defp established_member(conn) do
    {conn, user} = create_and_login_user(conn)
    {conn, backdate_registration!(user, Ads.grace_days() + 1)}
  end

  defp put_state(user, fields),
    do: Repo.update_all(from(u in User, where: u.id == ^user.id), set: fields)

  # The same member signed in on another device: a session of its own.
  defp second_device(user), do: Plug.Test.init_test_session(build_conn(), shell_session(user))

  defp an_hour_ago, do: DateTime.add(DateTime.utc_now(:second), -3601)

  defp counts(ad) do
    Repo.one(from(a in Ads.Ad, where: a.id == ^ad.id, select: {a.views_count, a.clicks_count}))
  end

  describe "where the ad shows" do
    test "a visitor sees the house ad on a profile, in the rail and near the top", %{conn: conn} do
      html = conn |> get(~p"/#{profile_owner()}") |> html_response(200)

      assert html =~ @rail
      assert html =~ @inline
      assert html =~ ">Ad</a>"
      assert html =~ @house
    end

    test "a member sees it in the feed", %{conn: conn} do
      {conn, _user} = established_member(conn)

      html = conn |> get(~p"/feed") |> html_response(200)

      assert html =~ @rail
      assert html =~ @inline
    end

    test "an approved booking replaces the house ad on its day", %{conn: conn} do
      insert(:ad,
        day: Ads.today(),
        title: "Acme sucht Leute",
        body: "Elixir-Entwicklung in Mainz.",
        url: "https://www.jobs.acme.example/elixir/?utm_source=vutuv"
      )

      {conn, _user} = established_member(conn)

      html = conn |> get(~p"/feed") |> html_response(200)

      # The title is the link, marked as paid for, and the address under it
      # says where it goes without the tracking query.
      [link] =
        Regex.run(
          ~r{<a[^>]*>\s*Acme sucht Leute\s*</a>},
          html |> String.split(@rail) |> List.last()
        )

      assert link =~ ~s(href="https://www.jobs.acme.example/elixir/?utm_source=vutuv")
      assert link =~ ~s(rel="sponsored noopener")
      assert link =~ ~s(target="_blank")
      assert html =~ "Elixir-Entwicklung in Mainz."
      assert html =~ ~r{>\s*jobs\.acme\.example/elixir\s*<}
      refute html =~ @house
    end

    test "a booking still waiting for approval never serves", %{conn: conn} do
      insert(:ad, day: Ads.today(), approved_at: nil, title: "Unapproved ad")

      html = conn |> get(~p"/#{profile_owner()}") |> html_response(200)

      refute html =~ "Unapproved ad"
      assert html =~ @house
    end

    test "the label reads Anzeige in German", %{conn: conn} do
      html =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/#{profile_owner()}")
        |> html_response(200)

      assert html =~ ">Anzeige</a>"
    end

    test "an ordinary page carries no ad any more", %{conn: conn} do
      html = conn |> get(~p"/community") |> html_response(200)

      refute html =~ "ad-slot"
    end

    test "the connected page keeps the ad it was handed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/#{profile_owner()}")

      assert has_element?(view, "#ad-slot-rail")
      assert has_element?(view, "#ad-slot-inline")
    end
  end

  describe "a visitor sees the ad on every profile" do
    test "cookies an earlier version wrote change nothing", %{conn: conn} do
      now = System.system_time(:second)

      assert conn
             |> put_req_cookie("vutuv_ad_seen", to_string(now - 60))
             |> put_req_cookie("vutuv_ad_dismissed", Date.to_iso8601(Ads.today()))
             |> get(~p"/#{profile_owner()}")
             |> html_response(200) =~ @rail
    end

    test "the card's script keeps nothing in the browser" do
      source = File.read!("assets/js/ad_slot.js")

      refute source =~ "document.cookie"
      refute source =~ ~r/(local|session)Storage|indexedDB/
    end

    test "sending a page takes no hour and writes no session", %{conn: conn} do
      path = ~p"/#{profile_owner()}"

      conn = get(conn, path)
      assert html_response(conn, 200) =~ @rail
      assert get_session(conn, :ad_seen_at) == nil

      assert conn |> get(path) |> html_response(200) =~ @rail
    end
  end

  # The rule is about the viewer, never the page: every `profile_owner/0` above
  # is a brand-new account and a visitor sees the ad on it. Where the fortnight
  # ends is pinned to the second in `Vutuv.AdsTest`; here it only has to reach
  # both pages, and the ad coming back afterwards is what every
  # `established_member/1` test below asserts.
  describe "the first two weeks after signing up" do
    test "a member who registered today sees none, in the feed or on a profile", %{conn: conn} do
      insert(:ad, day: Ads.today(), title: "Acme sucht Leute")
      {conn, user} = create_and_login_user(conn)

      refute conn |> get(~p"/feed") |> html_response(200) =~ "ad-slot"
      refute conn |> get(~p"/#{user}") |> html_response(200) =~ "ad-slot"
    end
  end

  describe "at most one ad an hour, for a member" do
    test "the hour starts when the card was seen, not when the page was sent", %{conn: conn} do
      {conn, user} = established_member(conn)

      assert conn |> get(~p"/feed") |> html_response(200) =~ @rail
      assert Repo.get!(User, user.id).ad_seen_at == nil
      assert conn |> get(~p"/feed") |> html_response(200) =~ @rail
    end

    test "the hour is kept on the server, so it spans devices", %{conn: conn} do
      {phone, user} = established_member(conn)
      desktop = second_device(user)

      {:ok, view, _html} = live(phone, ~p"/feed")
      render_hook(view, "ad-seen", %{})
      assert Repo.get!(User, user.id).ad_seen_at

      refute desktop |> get(~p"/feed") |> html_response(200) =~ @rail
      refute desktop |> get(~p"/#{user}") |> html_response(200) =~ @rail
    end

    test "once the hour is over the next ad comes", %{conn: conn} do
      {conn, user} = established_member(conn)
      put_state(user, ad_seen_at: an_hour_ago())

      assert conn |> get(~p"/feed") |> html_response(200) =~ @rail
    end

    test "a booked ad the member saw is kept for their history, one row per ad", %{conn: conn} do
      ad = insert(:ad, day: Ads.today())
      {conn, user} = established_member(conn)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_hook(view, "ad-seen", %{})
      put_state(user, ad_seen_at: an_hour_ago())
      {:ok, view, _html} = live(conn, ~p"/feed")
      render_hook(view, "ad-seen", %{})

      assert [sighting] = Repo.all(Sighting)
      assert {sighting.user_id, sighting.ad_id, sighting.times_seen} == {user.id, ad.id, 2}
    end

    test "the house ad takes the hour and leaves no sighting", %{conn: conn} do
      {conn, user} = established_member(conn)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_hook(view, "ad-seen", %{})

      assert Repo.get!(User, user.id).ad_seen_at
      assert Repo.all(Sighting) == []
    end

    test "a second tab whose card comes into view within the hour loses it", %{conn: conn} do
      ad = insert(:ad, day: Ads.today())
      {conn, user} = established_member(conn)

      {:ok, first, _html} = live(conn, ~p"/feed")
      {:ok, second, _html} = live(conn, ~p"/feed")
      render_hook(first, "ad-seen", %{})
      render_hook(second, "ad-seen", %{})

      assert has_element?(first, "#ad-slot-rail")
      refute has_element?(second, "#ad-slot-rail")
      assert [%Sighting{ad_id: ad_id, times_seen: 1}] = Repo.all(Sighting)
      assert ad_id == ad.id
      assert Repo.get!(User, user.id).ad_seen_at
    end

    test "a card the page no longer shows records nothing", %{conn: conn} do
      {conn, user} = established_member(conn)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_hook(view, "ad-expired", %{})
      render_hook(view, "ad-seen", %{})

      assert Repo.get!(User, user.id).ad_seen_at == nil
    end
  end

  describe "the ✕" do
    test "a member's ✕ keeps every ad away for the rest of the day, on every device", %{
      conn: conn
    } do
      {phone, user} = established_member(conn)
      desktop = second_device(user)

      {:ok, view, _html} = live(phone, ~p"/feed")
      view |> element("#ad-slot-rail button[phx-click=dismiss-ad]") |> render_click()

      refute has_element?(view, "#ad-slot-rail")
      refute has_element?(view, "#ad-slot-inline")
      assert Repo.get!(User, user.id).ads_dismissed_on == Ads.today()

      # The hour alone would let the next one through; the ✕ does not.
      put_state(user, ad_seen_at: nil)
      refute desktop |> get(~p"/feed") |> html_response(200) =~ @rail
    end

    test "yesterday's ✕ no longer counts", %{conn: conn} do
      {conn, user} = established_member(conn)
      put_state(user, ads_dismissed_on: Date.add(Ads.today(), -1))

      assert conn |> get(~p"/feed") |> html_response(200) =~ @rail
    end

    test "a visitor's ✕ closes this card and nothing more", %{conn: conn} do
      path = ~p"/#{profile_owner()}"
      {:ok, view, html} = live(conn, path)

      assert html =~ ~s(aria-label="Close this ad")
      refute html =~ "Hide ads for today"

      view |> element("#ad-slot-inline button[phx-click=dismiss-ad]") |> render_click()

      refute has_element?(view, "#ad-slot-inline")
      refute has_element?(view, "#ad-slot-rail")
    end

    test "a member's ✕ says it hides the ads for today", %{conn: conn} do
      {conn, _user} = established_member(conn)
      html = conn |> get(~p"/feed") |> html_response(200)

      assert html =~ ~s(aria-label="Hide ads for today")
      refute html =~ "Close this ad"
    end

    test "the live card carries its hook, its key and the countdown ring", %{conn: conn} do
      html = conn |> get(~p"/#{profile_owner()}") |> html_response(200)

      assert html =~ ~s(phx-hook="AdSlot")
      assert html =~ ~r/data-ad-key="\d+:house"/
      assert html =~ "data-ad-ring-arc"
      assert html =~ ~s(id="ad-slot-rail-ring" phx-update="ignore")
    end
  end

  describe "the numbers a booking gets" do
    test "a visitor's card is one view and one click per page, however often it reports", %{
      conn: conn
    } do
      ad = insert(:ad, day: Ads.today())
      {:ok, view, html} = live(conn, ~p"/#{profile_owner()}")
      assert html =~ "data-ad-link"

      for _ <- 1..3, do: render_hook(view, "ad-seen", %{})
      for _ <- 1..2, do: render_hook(view, "ad-click", %{})
      assert counts(ad) == {1, 1}

      {:ok, view, _html} = live(build_conn(), ~p"/#{profile_owner()}")
      render_hook(view, "ad-seen", %{})
      assert counts(ad) == {2, 1}
    end

    test "a member's card is a view only when it takes the hour", %{conn: conn} do
      ad = insert(:ad, day: Ads.today())
      {conn, _user} = established_member(conn)

      {:ok, first, _html} = live(conn, ~p"/feed")
      {:ok, second, _html} = live(conn, ~p"/feed")
      render_hook(first, "ad-seen", %{})
      render_hook(second, "ad-seen", %{})

      assert counts(ad) == {1, 0}
    end

    test "the house ad has nothing to count", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/#{profile_owner()}")
      render_hook(view, "ad-seen", %{})
      render_hook(view, "ad-click", %{})

      assert has_element?(view, "#ad-slot-rail")
    end
  end

  describe "the card's lifetime" do
    test "the card goes when the browser says its time is up, without closing the day", %{
      conn: conn
    } do
      {conn, user} = established_member(conn)
      {:ok, view, _html} = live(conn, ~p"/feed")

      render_hook(view, "ad-expired", %{})

      refute has_element?(view, "#ad-slot-rail")
      refute has_element?(view, "#ad-slot-inline")
      assert Repo.get!(User, user.id).ads_dismissed_on == nil
    end

    test "a reconnecting page gets back the ad its request served" do
      now = System.system_time(:second)
      todays = insert(:ad, day: Ads.today())

      assert %{banner: :house, served_at: served_at} =
               AdServing.slot_from_session(
                 %{"ad_slot" => "house", "ad_served_at" => now - 20},
                 now
               )

      assert served_at == now - 20

      assert %{banner: {:ad, ad}} =
               AdServing.slot_from_session(%{"ad_slot" => todays.id, "ad_served_at" => now}, now)

      assert ad.id == todays.id
    end

    test "a page reconnecting after the hour, or after its ad stopped serving, shows none" do
      now = System.system_time(:second)
      yesterdays = insert(:ad, day: Date.add(Ads.today(), -1))

      assert AdServing.slot_from_session(
               %{"ad_slot" => "house", "ad_served_at" => now - 3600},
               now
             ) == nil

      assert AdServing.slot_from_session(
               %{"ad_slot" => yesterdays.id, "ad_served_at" => now},
               now
             ) == nil
    end

    test "a page that was served no ad shows none" do
      assert AdServing.slot_from_session(%{}) == nil
    end
  end
end
