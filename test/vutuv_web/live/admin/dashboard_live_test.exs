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

  # `shell_session/2` (ConnCase) builds exactly the map a browser hands an
  # off-router `live_render` child: a real session token under "session_token".
  defp mount_dashboard(session),
    do: live_isolated(build_conn(), VutuvWeb.Admin.DashboardLive, session: session)

  describe "embedded on the admin home page" do
    test "the admin home renders the live dashboard at the top", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      html = html_response(get(conn, ~p"/admin"), 200)

      assert html =~ "admin-live-dashboard"
      assert html =~ "Currently online"
    end
  end

  # `/admin` behind the :admin pipeline gates the page, not this child's socket —
  # the standing rule for off-router `live_render` children. The mount resolves
  # the viewer from the cookie's session token and sends everyone else away.
  describe "the socket's own access control" do
    test "an anonymous socket is turned away" do
      insert(:user, email_confirmed?: true)

      assert {:error, {:live_redirect, %{to: "/"}}} = mount_dashboard(%{})
    end

    test "a signed-in member who is not an admin is turned away" do
      member = insert(:user, email_confirmed?: true)

      assert {:error, {:live_redirect, %{to: "/"}}} = mount_dashboard(shell_session(member))
    end

    # A token that has been revoked server-side (the member logged this device
    # out remotely) must not keep the socket alive either.
    test "a revoked session is turned away" do
      admin = insert(:user, admin?: true, email_confirmed?: true)
      session = shell_session(admin)

      session["session_token"]
      |> Vutuv.Sessions.active_session()
      |> Vutuv.Sessions.revoke()

      assert {:error, {:live_redirect, %{to: "/"}}} = mount_dashboard(session)
    end
  end

  describe "the live dashboard" do
    setup do
      admin = insert(:user, admin?: true, email_confirmed?: true)
      %{admin: admin, session: shell_session(admin)}
    end

    test "renders the activity tiles with formatted counts", %{session: session} do
      seed_posts_today(2)

      {:ok, view, _html} = mount_dashboard(session)

      assert has_element?(view, "#stat-online", "0")
      assert has_element?(view, "#stat-posts-today", "2")
      assert render(view) =~ "Direct messages"
      assert render(view) =~ "New members"
    end

    test "the currently-online count tracks presence live", %{session: session} do
      {:ok, view, _html} = mount_dashboard(session)

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

    test "the currently-online card links to each online member's profile", %{session: session} do
      {:ok, view, _html} = mount_dashboard(session)

      assert has_element?(view, "#online-members", "Nobody is online right now")

      Presence.subscribe_online()

      online = insert(:user)
      agent = start_supervised!({Agent, fn -> :ok end})
      {:ok, _ref} = Presence.track_user(agent, online.id)

      assert_receive %Broadcast{event: "presence_diff"}
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#online-members a[href='/#{online.username}']")
    end

    test "the new-members card links to the newest confirmed members", %{session: session} do
      member = insert(:user, email_confirmed?: true)
      unconfirmed = insert(:user, email_confirmed?: false)

      {:ok, view, _html} = mount_dashboard(session)

      assert has_element?(view, "#newest-members a[href='/#{member.username}']")
      refute has_element?(view, "#newest-members a[href='/#{unconfirmed.username}']")
    end

    test "a refresh picks up posts created after mount", %{session: session} do
      {:ok, view, _html} = mount_dashboard(session)

      assert has_element?(view, "#stat-posts-today", "0")

      seed_posts_today(3)
      send(view.pid, :refresh)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#stat-posts-today", "3")
    end

    # The gender breakdown is the only reason `users.gender` is collected, so
    # the card has to actually show it — and it has to show it over the right
    # denominator. A share computed against every member would count the silent
    # majority as an answer and quietly understate every group.
    test "the gender card counts shares against the members who answered", %{session: session} do
      insert_activated_user(gender: "female")
      insert_activated_user(gender: "female")
      insert_activated_user(gender: "male")
      insert_activated_user(gender: "diverse")
      insert_activated_user(gender: nil)
      insert_activated_user(gender: nil)

      {:ok, view, _html} = mount_dashboard(session)

      # 2 of the 4 answers, not 2 of the 6 members.
      assert has_element?(view, "#stat-gender [data-gender=female]", "50%")
      assert has_element?(view, "#stat-gender [data-gender=male]", "25%")
      assert has_element?(view, "#stat-gender [data-gender=diverse]", "25%")
      assert render(view) =~ "4 members who answered"
      # Three, not two: the admin this describe block signs in is a member of
      # the installation like any other, and gave no answer either.
      assert render(view) =~ "3 gave no answer"
    end

    # Nobody has answered yet: the shares must read as "no data" rather than as
    # a measured zero, and the card must not divide by zero.
    test "the gender card survives a membership that has answered nothing", %{session: session} do
      insert_activated_user(gender: nil)

      {:ok, view, _html} = mount_dashboard(session)

      assert has_element?(view, "#stat-gender [data-gender=female]", "—")
      refute render(view) =~ "0%"
    end

    # The admin's own stored locale is what decides, not the request's — the
    # socket resolves the viewer, so their setting beats whatever machine they
    # happen to be reading on (#1502).
    test "renders the admin's German labels when the admin's locale is de" do
      admin = insert(:user, admin?: true, email_confirmed?: true, locale: "de")

      {:ok, view, _html} = mount_dashboard(shell_session(admin))

      html = render(view)
      assert html =~ "Gerade online"
      assert html =~ "Direktnachrichten"
      assert html =~ "Neue Mitglieder"
      assert html =~ "Geschlecht"
      assert html =~ "ohne Angabe"
    end
  end
end
