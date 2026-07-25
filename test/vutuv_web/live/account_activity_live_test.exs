defmodule VutuvWeb.AccountActivityLiveTest do
  @moduledoc """
  The member's own account-activity log (/settings/activity): one row per event
  with a to-the-second stamp, search as you type, the kind filter, sortable
  columns and paging — plus the two things that make it a safeguard rather than
  a curiosity: the "Not you?" way out on every row, and the loud marker on an
  event somebody else caused.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.AccountEvents

  test "an anonymous visitor is sent away", %{conn: conn} do
    conn = get(conn, ~p"/settings/activity")
    assert redirected_to(conn) == ~p"/"
  end

  test "with nothing recorded it explains itself instead of showing a table", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    Vutuv.Repo.delete_all(AccountEvents.AccountEvent)
    _ = user

    {:ok, live, _html} = live(conn, ~p"/settings/activity")

    assert has_element?(live, "#no-activity")
    refute has_element?(live, "#activity-events")
  end

  describe "the table" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # The login itself already filed a "signed_in"; add two more kinds.
      :ok = AccountEvents.record(user, "passkey_added", details: %{nickname: "Work laptop"})

      :ok =
        AccountEvents.record(user, "username_changed",
          factor: "passkey",
          ip: "203.0.113.55",
          device: "Firefox on Linux",
          details: %{from: "old_name", to: "new_name"}
        )

      %{conn: conn, user: user}
    end

    test "reads as a sentence with a to-the-second stamp", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/settings/activity")

      assert has_element?(live, "#activity-events")
      assert html =~ "Username changed"
      assert html =~ "@old_name to @new_name"
      # The seconds are the point of this page, so the fallback text carries
      # them and the client rewrite is told to keep them.
      assert html =~ ~s(data-localtime="second")
      assert html =~ "Firefox on Linux"
      assert html =~ "203.0.113.55"
    end

    test "every row offers the way out", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/activity")
      assert html =~ ~p"/settings/security"
    end

    test "the kind filter narrows to one kind and stays in the URL", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/settings/activity")

      live
      |> element("#activity-filter")
      |> render_change(%{"kind" => "passkey_added", "q" => ""})

      # The rows, not the whole page: the kind <select> lists every kind that
      # occurs, so a page-wide match would pass whatever the table shows.
      rows = live |> element("#activity-events") |> render()
      assert rows =~ "Passkey added"
      refute rows =~ "Username changed"
      assert_patched(live, ~p"/settings/activity?kind=passkey_added")
    end

    test "search matches the device, the IP and the details", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/settings/activity")

      live |> element("#activity-filter") |> render_change(%{"q" => "Work laptop"})
      rows = live |> element("#activity-events") |> render()
      assert rows =~ "Passkey added"
      refute rows =~ "Username changed"

      live |> element("#activity-filter") |> render_change(%{"q" => "203.0.113.55"})
      rows = live |> element("#activity-events") |> render()
      assert rows =~ "Username changed"
      refute rows =~ "Passkey added"
    end

    test "a search that matches nothing says so and can be cleared", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/settings/activity")

      live |> element("#activity-filter") |> render_change(%{"q" => "zzzzz"})
      assert has_element?(live, "#no-matches")

      live |> element("#clear-filters") |> render_click()
      assert_patched(live, ~p"/settings/activity")
      refute has_element?(live, "#no-matches")
    end

    test "the time column sorts both ways", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/settings/activity")

      live |> element("#sort-time") |> render_click()
      assert_patched(live, ~p"/settings/activity?dir=asc")

      live |> element("#sort-time") |> render_click()
      assert_patched(live, ~p"/settings/activity")
    end

    test "sorting by kind is offered too", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/settings/activity")

      live |> element("#sort-kind") |> render_click()
      assert_patched(live, ~p"/settings/activity?sort=kind")
    end

    test "only the member's own events, never another account's", %{conn: conn, user: user} do
      stranger = insert(:user)
      :ok = AccountEvents.record(stranger, "signed_in", ip: "198.51.100.99")

      {:ok, live_view, _html} = live(conn, ~p"/settings/activity")

      refute live_view |> element("#activity-events") |> render() =~ "198.51.100.99"
      assert AccountEvents.count(user, AccountEvents.filters(%{})) == 3
    end
  end

  test "an event somebody else caused is marked as such", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    admin = insert(:user, admin?: true)
    :ok = AccountEvents.record(user, "account_frozen", factor: "admin", actor: admin)

    {:ok, live, _html} = live(conn, ~p"/settings/activity")

    assert has_element?(live, "[data-event-by-other]")
  end
end
