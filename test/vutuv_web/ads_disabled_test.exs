defmodule VutuvWeb.AdsDisabledTest do
  @moduledoc """
  The global on/off switch for the daily text-ad system
  (`config :vutuv, :ads_enabled`, read through `Vutuv.Ads.enabled?/0`).

  The test environment runs with ads **on** (so every ad test exercises the
  real flow), so each test here flips the flag **off** for its duration and
  asserts the system goes dormant: no banner serves, the public `/system/ads` flow
  and the admin review dashboard 404, and nothing can be booked - while
  `"ads"` stays a reserved slug so the handle is never claimed in the
  meantime.
  """

  use VutuvWeb.ConnCase

  alias Vutuv.Accounts.ReservedSlugs
  alias Vutuv.Ads

  setup do
    # The default (config/config.exs) is off; test config turns it on. Flip it
    # back off here and restore the test default afterwards.
    Application.put_env(:vutuv, :ads_enabled, false)
    on_exit(fn -> Application.put_env(:vutuv, :ads_enabled, true) end)
  end

  test "Ads.enabled?/0 follows the config switch" do
    refute Ads.enabled?()

    Application.put_env(:vutuv, :ads_enabled, true)
    assert Ads.enabled?()
  end

  test "no ad is served, not even on the pages that carry one", %{conn: conn} do
    # A booked, approved ad for today would normally serve; with the switch
    # off it does not. The member is aged past the two-week grace period, or
    # that rule alone would keep the card away and this would pass either way.
    insert(:ad, day: Ads.today(), title: "Acme sucht Leute")
    {conn, user} = create_and_login_user(conn)
    backdate_registration!(user, Ads.grace_days() + 1)

    refute conn |> get(~p"/feed") |> html_response(200) =~ "ad-slot"
    refute conn |> get(~p"/#{user}") |> html_response(200) =~ "ad-slot"
  end

  test "the seen-ads page does not exist", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    assert conn |> get("/system/ads/seen") |> html_response(404)
  end

  test "the public /system/ads pages 404 in every format", %{conn: conn} do
    assert conn |> get(~p"/system/ads") |> html_response(404)
    assert get(build_conn(), "/system/ads.md").status == 404
    assert get(build_conn(), "/system/ads.json").status == 404
  end

  test "the public booking flow 404s for a logged-in member", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    assert conn |> get(~p"/system/ads/new") |> html_response(404)
    assert conn |> get(~p"/system/ads/bookings") |> html_response(404)
  end

  test "the admin ad-review dashboard 404s for an admin", %{conn: conn} do
    {conn, _admin} = create_and_login_admin(conn)

    assert conn |> get(~p"/admin/ads") |> html_response(404)
  end

  test "the admin dashboard hides the ad-review card", %{conn: conn} do
    {conn, _admin} = create_and_login_admin(conn)

    html = conn |> get(~p"/admin") |> html_response(200)
    refute html =~ ~s(id="admin-ads-link")
  end

  test ~s("ads" stays a reserved slug regardless of the switch) do
    assert "ads" in ReservedSlugs.list()
  end
end
