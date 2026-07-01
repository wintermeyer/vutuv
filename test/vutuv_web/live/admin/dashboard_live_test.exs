defmodule VutuvWeb.Admin.DashboardLiveTest do
  @moduledoc """
  The live activity dashboard pinned to the top of the admin home page
  (`/admin`): an embedded LiveView showing how many members are online right
  now plus today/yesterday post, direct-message and sign-up counts, refreshing
  on its own.

  async: false - the "online now" tile reads the shared, global presence topic
  and the tests assert its count, so they must not interleave.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Phoenix.Socket.Broadcast
  alias Vutuv.BerlinTime
  alias VutuvWeb.Presence

  # Posts whose `inserted_at` lands on today's German calendar day, so they
  # count toward "today" no matter when the test runs.
  defp seed_posts_today(count) do
    {today_start, _} = BerlinTime.day_bounds_utc(BerlinTime.today())
    for _ <- 1..count, do: insert(:post, inserted_at: today_start, updated_at: today_start)
  end

  describe "embedded on the admin home page" do
    test "the admin home renders the live dashboard at the top", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      html = html_response(get(conn, ~p"/admin"), 200)

      assert html =~ "admin-live-dashboard"
      assert html =~ "Currently online"
    end
  end

  describe "the live dashboard" do
    test "renders the activity tiles with formatted counts", %{conn: conn} do
      seed_posts_today(2)

      {:ok, view, _html} = live_isolated(conn, VutuvWeb.Admin.DashboardLive)

      assert has_element?(view, "#stat-online", "0")
      assert has_element?(view, "#stat-posts-today", "2")
      assert render(view) =~ "Direct messages"
      assert render(view) =~ "New members"
    end

    test "the currently-online count tracks presence live", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.Admin.DashboardLive)
      assert has_element?(view, "#stat-online", "0")

      # Subscribe here too so we can wait for the join diff deterministically.
      Presence.subscribe_online()

      # A member comes online: a live process tracks them on the presence topic.
      online = insert(:user)
      agent = start_supervised!({Agent, fn -> :ok end})
      {:ok, _ref} = Presence.track_user(agent, online.id)

      # Once we have seen the diff, the dashboard has it queued too; flush its
      # mailbox so it has processed the same broadcast before we assert.
      assert_receive %Broadcast{event: "presence_diff"}
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#stat-online", "1")
    end

    test "the currently-online card links to each online member's profile", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.Admin.DashboardLive)
      assert has_element?(view, "#online-members", "Nobody is online right now")

      Presence.subscribe_online()

      online = insert(:user)
      agent = start_supervised!({Agent, fn -> :ok end})
      {:ok, _ref} = Presence.track_user(agent, online.id)

      assert_receive %Broadcast{event: "presence_diff"}
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#online-members a[href='/#{online.username}']")
    end

    test "the new-members card links to the newest confirmed members", %{conn: conn} do
      member = insert(:user, email_confirmed?: true)
      unconfirmed = insert(:user, email_confirmed?: false)

      {:ok, view, _html} = live_isolated(conn, VutuvWeb.Admin.DashboardLive)

      assert has_element?(view, "#newest-members a[href='/#{member.username}']")
      refute has_element?(view, "#newest-members a[href='/#{unconfirmed.username}']")
    end

    test "a refresh picks up posts created after mount", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.Admin.DashboardLive)
      assert has_element?(view, "#stat-posts-today", "0")

      seed_posts_today(3)
      send(view.pid, :refresh)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#stat-posts-today", "3")
    end

    test "renders the admin's German labels when the session carries the de locale", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.Admin.DashboardLive, session: %{"locale" => "de"})

      html = render(view)
      assert html =~ "Gerade online"
      assert html =~ "Direktnachrichten"
      assert html =~ "Neue Mitglieder"
    end
  end
end
