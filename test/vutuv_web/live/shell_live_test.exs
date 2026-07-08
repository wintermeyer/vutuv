defmodule VutuvWeb.ShellLiveTest do
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  @bell_badge ~s(a[title="Notifications"] span.bg-accent)
  @mail_badge ~s(a[title="Messages"] span.bg-accent)

  defp session_for(user, extra \\ %{}) do
    Map.merge(
      %{
        "user_id" => user.id,
        "user_name" => "Stefan Wintermeyer",
        "user_param" => "stefan"
      },
      extra
    )
  end

  defp user_with_unread_notification do
    user = insert(:user)
    insert(:follow, follower: insert(:user), followee: user)
    user
  end

  # An accepted conversation holding one message the user has not read.
  defp with_unread_message(user) do
    other = insert(:user)
    conversation = insert_conversation_between(other, user)
    {:ok, _} = Vutuv.Chat.send_message(other, conversation.id, "unread ping")
    user
  end

  test "renders the shell nav with the real unread notification count", %{conn: conn} do
    user = user_with_unread_notification()
    {:ok, view, html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    assert html =~ "vutuv"
    assert has_element?(view, "#app-shell")
    # one unread follower event; no conversations, so no messages badge
    assert has_element?(view, @bell_badge, "1")
    refute has_element?(view, @mail_badge)
  end

  test "renders the real unread conversation count", %{conn: conn} do
    user = with_unread_message(insert(:user))
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    assert has_element?(view, @mail_badge, "1")
  end

  test "zeroes the messages badge on the messages page but not a look-alike slug", %{conn: conn} do
    user = with_unread_message(insert(:user))

    # On the messages page itself the badge deliberately starts at zero.
    {:ok, on_page, _} =
      live_isolated(conn, VutuvWeb.ShellLive,
        session: session_for(user, %{"path" => "/messages"})
      )

    refute has_element?(on_page, @mail_badge)

    # A profile whose slug merely BEGINS with "messages" is not that page,
    # so the real unread count must still show.
    {:ok, on_profile, _} =
      live_isolated(conn, VutuvWeb.ShellLive,
        session: session_for(user, %{"path" => "/messagesanna"})
      )

    assert has_element?(on_profile, @mail_badge, "1")
  end

  test "the messages badge counts unread conversations, not message events", %{conn: conn} do
    user = with_unread_message(insert(:user))
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    assert has_element?(view, @mail_badge, "1")

    # A repeat message in the same, already-unread conversation: still one
    # unread conversation, not two.
    send(view.pid, {:new_message, %{conversation_id: "x"}})
    assert has_element?(view, @mail_badge, "1")

    # A message opening a second unread conversation: now two.
    with_unread_message(user)
    send(view.pid, {:new_message, %{conversation_id: "y"}})
    assert has_element?(view, @mail_badge, "2")
  end

  test "reading one conversation leaves the other conversations' badge intact", %{conn: conn} do
    user = insert(:user)
    other = insert(:user)
    conversation = insert_conversation_between(other, user)
    {:ok, _} = Vutuv.Chat.send_message(other, conversation.id, "unread ping")
    with_unread_message(user)

    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))
    assert has_element?(view, @mail_badge, "2")

    # The member opens conversation one: MessageLive marks it read and
    # broadcasts :messages_read. The second conversation is still unread —
    # the badge must drop to 1, not be blanked to 0.
    Vutuv.Chat.mark_read(user, conversation.id)
    send(view.pid, :messages_read)

    assert has_element?(view, @mail_badge, "1")
  end

  test "reading the only unread conversation clears the messages badge", %{conn: conn} do
    user = insert(:user)
    other = insert(:user)
    conversation = insert_conversation_between(other, user)
    {:ok, _} = Vutuv.Chat.send_message(other, conversation.id, "unread ping")

    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))
    assert has_element?(view, @mail_badge, "1")

    Vutuv.Chat.mark_read(user, conversation.id)
    send(view.pid, :messages_read)

    refute has_element?(view, @mail_badge)
  end

  test "already-read events don't count toward the badge", %{conn: conn} do
    user = user_with_unread_notification()
    Vutuv.Activity.mark_notifications_read(user.id)

    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    refute has_element?(view, @bell_badge)
  end

  describe "brand link" do
    test "points to the member's own profile on the feed", %{conn: conn} do
      # On /feed the logo would only round-trip through "/" back to the feed,
      # so there it deep-links to the member's own profile instead.
      user = insert(:user)
      session = session_for(user, %{"path" => "/feed"})
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session)

      assert has_element?(view, ~s(header a[data-brand][href="/stefan"]), "vutuv")
    end

    test "stays the home link on every other page", %{conn: conn} do
      user = insert(:user)
      session = session_for(user, %{"path" => "/search"})
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session)

      assert has_element?(view, ~s(header a[data-brand][href="/"]), "vutuv")
    end

    test "stays the home link when logged out", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: %{"path" => "/feed"})

      assert has_element?(view, ~s(header a[data-brand][href="/"]), "vutuv")
    end

    test "the real feed page wires the brand link to the member's profile", %{conn: conn} do
      # End to end through the layout: the feed page must hand its path to the
      # shell (session "path"), while a sibling page keeps the home link.
      {conn, user} = create_and_login_user(conn)

      feed_doc = conn |> get(~p"/feed") |> html_response(200) |> LazyHTML.from_document()

      assert feed_doc |> LazyHTML.query("a[data-brand]") |> LazyHTML.attribute("href") ==
               ["/#{user.username}"]

      search_doc = conn |> get(~p"/search") |> html_response(200) |> LazyHTML.from_document()

      assert search_doc |> LazyHTML.query("a[data-brand]") |> LazyHTML.attribute("href") ==
               ["/"]
    end
  end

  test "shows the user's avatar in the top bar when they have one", %{conn: conn} do
    user = insert(:user)
    session = session_for(user, %{"user_avatar" => "/avatars/#{user.id}/Stefan%20W_thumb.jpg"})
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session)

    assert has_element?(view, ~s(summary[title="Stefan Wintermeyer"] img))
    refute has_element?(view, ~s(summary[title="Stefan Wintermeyer"]), "SW")
  end

  test "falls back to initials when the user has no avatar", %{conn: conn} do
    user = insert(:user)
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    assert has_element?(view, ~s(summary[title="Stefan Wintermeyer"]), "SW")
    refute has_element?(view, ~s(summary[title="Stefan Wintermeyer"] img))
  end

  test "the top-bar monogram uses the first+last initials, not the honorific title", %{conn: conn} do
    # Regression: "Dr. Anna Schmidt" showed "DA" in the shell instead of "AS".
    user = insert(:user)
    session = session_for(user, %{"user_name" => "Dr. Anna Schmidt", "user_initials" => "AS"})
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session)

    assert has_element?(view, ~s(summary[title="Dr. Anna Schmidt"]), "AS")
    refute has_element?(view, ~s(summary[title="Dr. Anna Schmidt"]), "DA")
  end

  test "the avatar opens an account menu linking to every account area", %{conn: conn} do
    user = insert(:user)
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    menu = "details[data-account-menu]"
    assert has_element?(view, menu)
    # Identity header + the content/settings destinations a member expects to
    # find behind their avatar, so the whole account surface is one click away.
    assert has_element?(view, ~s(#{menu} a[href="/stefan"]))
    assert has_element?(view, ~s(#{menu} a[href="/bookmarks"]))
    assert has_element?(view, ~s(#{menu} a[href="/likes"]))
    # "Settings" opens the user-agnostic settings hub (the one map of
    # everything editable), not the profile-basics form it used to alias.
    assert has_element?(view, ~s(#{menu} a[href="/settings"]))
    # Log out folds into the menu (its own door icon in the bar is gone).
    assert has_element?(view, ~s(#{menu} a[href="/logout"][data-method="delete"]))
    # The desktop-only trigger that opens the keyboard-shortcuts overlay.
    assert has_element?(view, ~s(#{menu} [data-shortcuts-trigger]))
  end

  test "logged out there is no account menu and no log out link", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})

    refute has_element?(view, "details[data-account-menu]")
    refute has_element?(view, ~s(a[href="/logout"]))
  end

  test "a logged-in dead render carries the avatar through shell_session", %{conn: conn} do
    # End to end through the app layout: LayoutHTML.shell_session/1 must hand
    # the avatar URL to the embedded shell on classic controller pages too.
    {conn, user} = create_and_login_user(conn)

    {:ok, user} =
      Vutuv.Repo.update(Ecto.Changeset.change(user, avatar: "me.jpg"))

    # The search page renders no avatars of its own, so the only avatar URL in
    # the response is the one the shell chrome puts in the top bar.
    response = conn |> get(~p"/search") |> html_response(200)
    assert response =~ ~s(/avatars/#{user.id}/)
  end

  test "shows a Log in button when logged out", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})
    assert has_element?(view, "a", "Log in")
    refute has_element?(view, "span.bg-accent")
  end

  test "the anonymous bottom bar offers Log in instead of dead-end tabs", %{conn: conn} do
    # Messages and Alerts only redirect a visitor to the login page, so the
    # mobile tab bar replaces them with a Log in tab while logged out.
    {:ok, view, html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})

    assert has_element?(view, ~s(nav a[href="/login"]))
    refute html =~ ~s(href="/messages")
    refute html =~ ~s(href="/notifications")
  end

  test "the logged-in bottom bar keeps Messages and Alerts", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    html = conn |> get(~p"/search") |> html_response(200)

    assert html =~ ~s(href="/messages")
    assert html =~ ~s(href="/notifications")
  end

  test "renders the anonymous shell for a stale cookie user_id with no profile data", %{
    conn: conn
  } do
    # Phoenix.LiveView.Static merges the raw browser session UNDER the curated
    # :session (LayoutHTML.shell_session/1). A cookie pointing at a
    # since-deleted or UUID-re-keyed account makes shell_session/1 return %{}
    # (no current_user), but the browser session's bare `user_id` still leaks
    # in here without the profile fields. The shell must treat that as logged
    # out, not render the logged-in chrome — which needs the `user_param` only
    # shell_session supplies — and crash on ~p"/#{nil}".
    stale = %{"user_id" => Vutuv.UUIDv7.generate()}
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: stale)

    assert has_element?(view, "a", "Log in")
    refute has_element?(view, ~s(a[title] img))
    refute has_element?(view, "span.bg-accent")
  end

  test "a new-notification event recomputes the bell badge from the source of truth", %{
    conn: conn
  } do
    user = user_with_unread_notification()
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))
    assert has_element?(view, @bell_badge, "1")

    # A second real unread event lands, then the push notification announces it.
    # The shell recomputes (like the messages badge) rather than blindly +1'ing,
    # so the badge reflects the true count and can't drift.
    insert(:follow, follower: insert(:user), followee: user)
    send(view.pid, {:new_notification, %{text: "hi"}})

    assert has_element?(view, @bell_badge, "2")
  end

  test "a :notifications_changed event recomputes (lowers) the bell badge", %{conn: conn} do
    # Regression for #782: the shell must recompute its unread count on a
    # :notifications_changed nudge, not only ever increment, so a silent drop
    # (here an unfollow that undoes a mutual follow) is reflected without a full
    # page reload re-seeding it.
    recipient = insert(:user)
    other = insert(:user)
    connect!(recipient, other)

    {:ok, view, _html} =
      live_isolated(conn, VutuvWeb.ShellLive, session: session_for(recipient))

    # Seeded from the DB: a new follower plus the derived connection event.
    assert has_element?(view, @bell_badge)

    # The other side unfollows: the pair is no longer mutual, so both the
    # follower and the connection events are gone. On the recompute the badge
    # must drop to 0.
    fid = Vutuv.Social.follow_id(other.id, recipient.id)
    Vutuv.Social.unfollow!(other.id, fid)
    send(view.pid, :notifications_changed)

    refute has_element?(view, @bell_badge)
  end

  test "the badge for the page being viewed starts at zero (no read-broadcast race)", %{
    conn: conn
  } do
    user = with_unread_message(user_with_unread_notification())
    session = session_for(user, %{"path" => "/notifications"})
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session)

    refute has_element?(view, @bell_badge)
    # the messages badge is unaffected
    assert has_element?(view, @mail_badge, "1")
  end

  test "marking notifications read clears the notification badge", %{conn: conn} do
    user = with_unread_message(user_with_unread_notification())
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    send(view.pid, :notifications_read)

    refute has_element?(view, @bell_badge)
    # the messages badge is untouched
    assert has_element?(view, @mail_badge, "1")
  end

  # The shell feeds a browser-tab title indicator (the TabBadge JS hook) so a
  # backgrounded tab shows new activity: an exact "(N)" for unread messages +
  # notifications, and a "new posts" nudge for feed posts. It pushes the total
  # on connect and re-pushes it whenever either count changes.
  describe "browser-tab title badge" do
    test "carries the tab-badge hook only for a logged-in member", %{conn: conn} do
      user = insert(:user)
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))
      assert has_element?(view, "#tab-badge[phx-hook='TabBadge']")

      {:ok, anon, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})
      refute has_element?(anon, "#tab-badge")
    end

    test "pushes the unread total to the hook on connect", %{conn: conn} do
      user = with_unread_message(user_with_unread_notification())
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

      # one unread notification + one unread conversation
      assert_push_event(view, "tab:badge", %{unread: 2})
    end

    test "re-pushes a raised total when a message arrives", %{conn: conn} do
      user = user_with_unread_notification()
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))
      assert_push_event(view, "tab:badge", %{unread: 1})

      with_unread_message(user)
      send(view.pid, {:new_message, %{conversation_id: "y"}})
      assert_push_event(view, "tab:badge", %{unread: 2})
    end

    test "re-pushes a lowered total when notifications are read", %{conn: conn} do
      user = with_unread_message(user_with_unread_notification())
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))
      assert_push_event(view, "tab:badge", %{unread: 2})

      send(view.pid, :notifications_read)
      # only the unread conversation remains
      assert_push_event(view, "tab:badge", %{unread: 1})
    end

    test "a new feed post from someone else nudges the tab title", %{conn: conn} do
      user = insert(:user)
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

      send(
        view.pid,
        {:new_post, %{post_id: Vutuv.UUIDv7.generate(), author_id: insert(:user).id}}
      )

      assert_push_event(view, "tab:new_post", %{})
    end

    test "your own new post does not badge your own tab", %{conn: conn} do
      # broadcast_to_followers/2 also delivers {:new_post} to the author, so the
      # shell must ignore a post it wrote itself.
      user = insert(:user)
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

      send(view.pid, {:new_post, %{post_id: Vutuv.UUIDv7.generate(), author_id: user.id}})
      refute_push_event(view, "tab:new_post", %{})
    end
  end
end
