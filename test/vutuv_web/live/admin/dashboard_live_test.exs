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

  # Tracks `user` on the global presence topic and returns once `view` has
  # really processed the resulting diff. We subscribe here too so the wait is
  # deterministic: seeing the broadcast ourselves means the dashboard has it
  # queued, and `:sys.get_state/1` then flushes its mailbox.
  defp bring_online(view, user) do
    Presence.subscribe_online()
    agent = start_supervised!({Agent, fn -> :ok end}, id: {:presence, user.id})
    {:ok, _ref} = Presence.track_user(agent, user.id)

    assert_receive %Broadcast{event: "presence_diff"}
    _ = :sys.get_state(view.pid)
    :ok
  end

  # The people card lists one set at a time, new members first; the online list
  # sits behind its segment.
  defp show_online(view) do
    view |> element("#dashboard-tab-online") |> render_click()
    view
  end

  defp tag_member(member, count) do
    for _ <- 1..count, do: insert(:user_tag, user: member, tag: insert(:tag))
  end

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
      assert render(view) =~ "Messages"
      assert render(view) =~ "New today"
    end

    # Variant C of the 2026-09-21 demo: on a phone the four figures come first
    # and one list below them, so an admin who opens the page for today's
    # sign-ups does not scroll past everybody online to reach them.
    test "the people card opens on the new members and switches to who is online", %{
      session: session
    } do
      {:ok, view, _html} = mount_dashboard(session)

      assert has_element?(view, "#newest-members")
      refute has_element?(view, "#online-members")
      assert has_element?(view, "#dashboard-tab-new[aria-pressed=true]")

      show_online(view)

      assert has_element?(view, "#online-members")
      refute has_element?(view, "#newest-members")
      assert has_element?(view, "#dashboard-tab-online[aria-pressed=true]")

      # The figure tile is the same switch, and the bigger target on a phone.
      view |> element("#tile-new") |> render_click()

      assert has_element?(view, "#newest-members")
    end

    test "the segments carry a short label for a phone beside the full one", %{session: session} do
      {:ok, view, _html} = mount_dashboard(session)

      assert has_element?(view, "#dashboard-tab-new [data-label=short]", "New")
      assert has_element?(view, "#dashboard-tab-new [data-label=full]", "New members")
      assert has_element?(view, "#dashboard-tab-online [data-label=short]", "Online")
      assert has_element?(view, "#dashboard-tab-online [data-label=full]", "Currently online")
    end

    test "a new member's row names where they live and their first three tags", %{
      session: session
    } do
      member = insert(:activated_user)
      insert(:address, user: member, city: "Leipzig", country: "Germany")
      tag_member(member, 5)

      {:ok, view, _html} = mount_dashboard(session)
      row = "#newest-members-#{member.id}"

      assert has_element?(view, "#{row} [data-member-place]", "Leipzig, Germany")
      assert length(elements(render(view), "#{row} [data-member-tag]")) == 3
      assert has_element?(view, "#{row} [data-member-more-tags]", "+2 more tags")
    end

    # The count is derived from the tag summary on every render. Derived once
    # and stashed beside it, change tracking skipped it and the row kept the
    # figure from mount after the member added a tag.
    test "the rest-of-tags count follows a refresh", %{session: session} do
      member = insert(:activated_user)
      tag_member(member, 5)

      {:ok, view, _html} = mount_dashboard(session)
      row = "#newest-members-#{member.id}"
      assert has_element?(view, "#{row} [data-member-more-tags]", "+2 more tags")

      tag_member(member, 1)
      send(view.pid, :refresh)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#{row} [data-member-more-tags]", "+3 more tags")
    end

    test "a row with three tags or fewer shows no count, and one without an address no place", %{
      session: session
    } do
      member = insert(:activated_user)
      tag_member(member, 3)

      {:ok, view, _html} = mount_dashboard(session)
      row = "#newest-members-#{member.id}"

      assert length(elements(render(view), "#{row} [data-member-tag]")) == 3
      refute has_element?(view, "#{row} [data-member-more-tags]")
      refute has_element?(view, "#{row} [data-member-place]")
    end

    test "the currently-online count tracks presence live", %{session: session} do
      {:ok, view, _html} = mount_dashboard(session)

      assert has_element?(view, "#stat-online", "0")

      # A member comes online: a live process tracks them on the presence topic.
      bring_online(view, insert(:user))

      assert has_element?(view, "#stat-online", "1")
    end

    test "the currently-online card links to each online member's profile", %{session: session} do
      {:ok, view, _html} = mount_dashboard(session)

      show_online(view)
      assert has_element?(view, "#online-members", "Nobody is online right now")

      online = insert(:user)
      bring_online(view, online)

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

    # ── The admin's own relationship to the listed members ──────────────────
    #
    # The two cards are where an admin meets the people who just signed up, so
    # each row carries the follow pill and, when it applies, the chip that says
    # the member follows them back. Both are keyed on `phx-value-*` and
    # `data-profile-relationship` rather than on a translated word, which is the
    # steadier probe.

    test "a member the admin does not follow gets a Follow pill", %{session: session} do
      member = insert(:user, email_confirmed?: true)

      {:ok, view, _html} = mount_dashboard(session)

      assert has_element?(view, "#newest-members button[phx-value-followee='#{member.id}']")
      refute has_element?(view, "#newest-members [data-profile-relationship]")
    end

    test "the pill follows the member over the socket, with no reload", %{
      admin: admin,
      session: session
    } do
      member = insert(:user, email_confirmed?: true)

      {:ok, view, _html} = mount_dashboard(session)

      view
      |> element("#newest-members button[phx-value-followee='#{member.id}']")
      |> render_click()

      assert Vutuv.Social.user_follows_user?(admin.id, member.id)

      # The pill has flipped to its "Following" state, which is the unfollow
      # half: it now carries the edge id rather than the followee id.
      follow_id = Vutuv.Social.follow_id(admin.id, member.id)
      assert has_element?(view, "#newest-members button[phx-value-id='#{follow_id}']")
      refute has_element?(view, "#newest-members button[phx-value-followee='#{member.id}']")
    end

    test "the same pill takes the follow back", %{admin: admin, session: session} do
      member = insert(:user, email_confirmed?: true)
      follow = follow!(admin, member)

      {:ok, view, _html} = mount_dashboard(session)

      view
      |> element("#newest-members button[phx-value-id='#{follow.id}']")
      |> render_click()

      refute Vutuv.Social.user_follows_user?(admin.id, member.id)
      assert has_element?(view, "#newest-members button[phx-value-followee='#{member.id}']")
    end

    # The whole point of the chip: an admin greeting today's sign-ups can see at
    # a glance which of them already came to them.
    test "a member who follows the admin is marked, and a mutual follow reads as connected", %{
      admin: admin,
      session: session
    } do
      inbound = insert(:user, email_confirmed?: true)
      mutual = insert(:user, email_confirmed?: true)
      follow!(inbound, admin)
      connect!(admin, mutual)

      {:ok, view, _html} = mount_dashboard(session)

      assert has_element?(view, "#newest-members [data-profile-relationship=inbound]")
      assert has_element?(view, "#newest-members [data-profile-relationship=mutual]")

      # The one-way inbound follow is still an offer to take up, the mutual one
      # is not.
      assert has_element?(view, "#newest-members button[phx-value-followee='#{inbound.id}']")
      refute has_element?(view, "#newest-members button[phx-value-followee='#{mutual.id}']")
    end

    # The admin is in the "currently online" list themselves — they are reading
    # the page. A pill there would be a control that cannot do anything.
    test "the admin's own row carries no follow pill", %{admin: admin, session: session} do
      {:ok, view, _html} = mount_dashboard(session)

      bring_online(view, admin)
      show_online(view)

      assert has_element?(view, "#online-members a[href='/#{admin.username}']")
      refute has_element?(view, "#online-members button[phx-value-followee='#{admin.id}']")
    end

    # The admin's own stored locale is what decides, not the request's — the
    # socket resolves the viewer, so their setting beats whatever machine they
    # happen to be reading on (#1502).
    test "renders the admin's German labels when the admin's locale is de" do
      admin = insert(:user, admin?: true, email_confirmed?: true, locale: "de")

      {:ok, view, _html} = mount_dashboard(shell_session(admin))

      html = render(view)
      assert html =~ "Neu heute"
      assert html =~ "Nachrichten"
      assert html =~ "Geschlecht"
      assert html =~ "ohne Angabe"

      assert has_element?(view, "#dashboard-tab-new [data-label=short]", "Neu")
      assert has_element?(view, "#dashboard-tab-new [data-label=full]", "Neue Mitglieder")
      assert has_element?(view, "#dashboard-tab-online [data-label=short]", "Online")
      assert has_element?(view, "#dashboard-tab-online [data-label=full]", "Gerade online")
    end

    # `addresses.country` stores the English name; a German admin reads the
    # German one.
    test "a German admin reads the member's country in German" do
      admin = insert(:user, admin?: true, email_confirmed?: true, locale: "de")
      member = insert(:activated_user)
      insert(:address, user: member, city: "London", country: "United Kingdom")

      {:ok, view, _html} = mount_dashboard(shell_session(admin))

      assert has_element?(
               view,
               "#newest-members-#{member.id} [data-member-place]",
               "London, Vereinigtes Königreich"
             )

      assert has_element?(view, "#stat-members-yesterday", "gestern 0")
    end
  end
end
