defmodule VutuvWeb.Admin.ActivityLiveTest do
  @moduledoc """
  The installation-wide account-activity log (/admin/activity): admin-only, one
  member filter, a free-text search, sortable columns — and the part that makes
  it accountable, the page recording its own access in the reading admin's log.
  """
  use VutuvWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Vutuv.AccountEvents
  alias Vutuv.AccountEvents.AccountEvent

  defp views_by(admin) do
    Repo.all(
      from(e in AccountEvent,
        where: e.user_id == ^admin.id and e.kind == "activity_log_viewed",
        order_by: [asc: e.inserted_at]
      )
    )
  end

  test "an ordinary member cannot open it", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    conn = get(conn, ~p"/admin/activity")
    assert conn.status == 403
  end

  test "an anonymous visitor cannot open it", %{conn: conn} do
    conn = get(conn, ~p"/admin/activity")
    assert redirected_to(conn) == ~p"/"
  end

  describe "the table" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)

      anna = insert(:user, username: "admin-log-anna", first_name: "Anna")
      bert = insert(:user, username: "admin-log-bert", first_name: "Bert")

      :ok = AccountEvents.record(anna, "passkey_added", details: %{nickname: "Anna's phone"})
      :ok = AccountEvents.record(bert, "totp_enabled", ip: "198.51.100.42")

      %{conn: conn, admin: admin, anna: anna, bert: bert}
    end

    test "shows every member's events", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/activity")

      rows = live |> element("#activity-events") |> render()
      assert rows =~ "admin-log-anna"
      assert rows =~ "admin-log-bert"
    end

    test "the member filter narrows to one account and rides the URL", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/activity")

      live |> element("#activity-filter") |> render_change(%{"member" => "admin-log-anna"})

      rows = live |> element("#activity-events") |> render()
      assert rows =~ "admin-log-anna"
      refute rows =~ "admin-log-bert"
      assert_patched(live, ~p"/admin/activity?member=admin-log-anna")
    end

    test "a handle in a row is itself a filter", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/activity")

      live
      |> element("#activity-events button[phx-value-handle='admin-log-bert']")
      |> render_click()

      assert_patched(live, ~p"/admin/activity?member=admin-log-bert")
    end

    test "search matches the IP", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/activity")

      live |> element("#activity-filter") |> render_change(%{"q" => "198.51.100.42"})

      rows = live |> element("#activity-events") |> render()
      assert rows =~ "admin-log-bert"
      refute rows =~ "admin-log-anna"
    end

    test "sorts by member", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/activity")

      live |> element("#sort-member") |> render_click()
      assert_patched(live, ~p"/admin/activity?sort=member")
    end
  end

  describe "reading somebody else's log is itself recorded" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      member = insert(:user, username: "watched-member")
      :ok = AccountEvents.record(member, "signed_in")
      %{conn: conn, admin: admin, member: member}
    end

    test "opening the page files one entry on the ADMIN's own log", %{conn: conn, admin: admin} do
      {:ok, _live, _html} = live(conn, ~p"/admin/activity")

      assert [event] = views_by(admin)
      assert event.details == %{}
    end

    test "narrowing to a member records which member was looked at", %{conn: conn, admin: admin} do
      {:ok, live, _html} = live(conn, ~p"/admin/activity")

      live |> element("#activity-filter") |> render_change(%{"member" => "watched-member"})

      assert [_open, scoped] = views_by(admin)
      assert scoped.details == %{"member" => "watched-member"}
    end

    test "paging and sorting inside one view do not file a row each", %{conn: conn, admin: admin} do
      {:ok, live, _html} = live(conn, ~p"/admin/activity")

      live |> element("#activity-filter") |> render_change(%{"member" => "watched-member"})
      live |> element("#sort-kind") |> render_click()
      live |> element("#sort-kind") |> render_click()

      assert length(views_by(admin)) == 2
    end

    test "a search that reveals nobody is not recorded as a reveal", %{conn: conn, admin: admin} do
      {:ok, live, _html} = live(conn, ~p"/admin/activity")

      live |> element("#activity-filter") |> render_change(%{"member" => "nobody-by-that-name"})

      assert [_only_the_page_open] = views_by(admin)
    end
  end
end
