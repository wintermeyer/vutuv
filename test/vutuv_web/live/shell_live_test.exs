defmodule VutuvWeb.ShellLiveTest do
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Sessions

  @bell_badge ~s(a[title="Notifications"] span.bg-accent)
  @mail_badge ~s(a[title="Messages"] span.bg-accent)

  # The shell authenticates the live socket from the cookie's session_token
  # (issue #1036), so a test drives it with a real active session and reads the
  # chrome back from the resolved user, not a curated map. `extra` still carries
  # the non-identity keys the shell reads straight from the session (`path`,
  # `locale`); any leftover curated identity key is simply ignored now.
  defp session_for(user, extra \\ %{}) do
    {token, _session} = Sessions.start_session(user, build_conn(), alert: false)
    Map.merge(%{"session_token" => token}, extra)
  end

  # The member whose name/handle the chrome assertions below expect. This module
  # is synchronous, so the fixed "stefan" handle is safe (no async file mints it
  # at the same time).
  defp stefan(attrs \\ []) do
    insert(
      :user,
      Keyword.merge([first_name: "Stefan", last_name: "Wintermeyer", username: "stefan"], attrs)
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
      user = stefan()
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
    user = stefan(avatar: "me.jpg")
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    assert has_element?(view, ~s(summary[title="Stefan Wintermeyer"] img))
    refute has_element?(view, ~s(summary[title="Stefan Wintermeyer"]), "SW")
  end

  test "falls back to initials when the user has no avatar", %{conn: conn} do
    user = stefan()
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    assert has_element?(view, ~s(summary[title="Stefan Wintermeyer"]), "SW")
    refute has_element?(view, ~s(summary[title="Stefan Wintermeyer"] img))
  end

  test "the top-bar monogram uses the first+last initials, not the honorific title", %{conn: conn} do
    # Regression: "Dr. Anna Schmidt" showed "DA" in the shell instead of "AS".
    user =
      insert(:user,
        honorific_prefix: "Dr.",
        first_name: "Anna",
        last_name: "Schmidt",
        username: "anna-schmidt"
      )

    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    assert has_element?(view, ~s(summary[title="Dr. Anna Schmidt"]), "AS")
    refute has_element?(view, ~s(summary[title="Dr. Anna Schmidt"]), "DA")
  end

  test "the avatar opens an account menu linking to every account area", %{conn: conn} do
    user = stefan()
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    menu = "details[data-account-menu]"
    assert has_element?(view, menu)
    # Identity header + the content/settings destinations a member expects to
    # find behind their avatar, so the whole account surface is one click away.
    assert has_element?(view, ~s(#{menu} a[href="/stefan"]))
    assert has_element?(view, ~s(#{menu} a[href="/bookmarks"]))
    assert has_element?(view, ~s(#{menu} a[href="/likes"]))
    # The member's "Your organizations" hub: their own pages, the explainer and
    # the add call to action (the public browse directory stays in the footer).
    assert has_element?(view, ~s(#{menu} a[href="/settings/organizations"]))
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

  describe "profile navigation" do
    test "the desktop nav carries an explicit Profile link to the member's profile", %{
      conn: conn
    } do
      # The logo already deep-links to the profile on /feed, but that is not
      # obvious; a named "Profile" nav item makes the member's own profile a
      # first-class, discoverable destination.
      user = stefan()
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

      assert has_element?(view, ~s(nav a[data-nav-profile][href="/stefan"]), "Profile")
    end

    test "the mobile tab bar carries a Profile tab to the member's profile", %{conn: conn} do
      # Desktop is not the only surface: the bottom tab bar gets a Profile tab
      # too, so phone visitors can reach their profile without hunting for it.
      user = stefan()
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

      assert has_element?(view, ~s(nav a[data-mobile-profile][href="/stefan"]), "Profile")
      # Five tabs now (Feed, Search, Messages, Alerts, Profile), so the grid grows.
      assert has_element?(view, "nav.grid-cols-5")
    end

    test "logged out there is no Profile nav link or tab", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})

      refute has_element?(view, "[data-nav-profile]")
      refute has_element?(view, "[data-mobile-profile]")
    end
  end

  describe "active navigation" do
    # The member must be able to tell which page they are on: the matching nav
    # item (desktop top bar and mobile bottom bar alike) is marked as the
    # current page (aria-current) and styled distinctly instead of behaving
    # like a normal clickable link.
    test "the desktop nav marks the current page as active", %{conn: conn} do
      user = insert(:user)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user, %{"path" => "/feed"}))

      assert has_element?(view, ~s(nav a[href="/feed"][aria-current="page"]), "Feed")
      # No other nav item claims to be the current page.
      refute has_element?(view, ~s(nav a[data-nav-profile][aria-current="page"]))
      refute has_element?(view, ~s(nav a[href="/jobs"][aria-current="page"]))
    end

    test "the Profile item is active on the member's own profile (and its subpages)", %{
      conn: conn
    } do
      user = stefan()

      for path <- ["/stefan", "/stefan/tags"] do
        {:ok, view, _html} =
          live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user, %{"path" => path}))

        assert has_element?(view, ~s(a[data-nav-profile][aria-current="page"]))
        assert has_element?(view, ~s(a[data-mobile-profile][aria-current="page"]))
        # A different member's profile must not activate my Profile item.
        refute has_element?(view, ~s(a[href="/feed"][aria-current="page"]))
      end
    end

    test "viewing another member's profile does not activate my Profile item", %{conn: conn} do
      user = insert(:user)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user, %{"path" => "/anna"}))

      refute has_element?(view, ~s(a[data-nav-profile][aria-current="page"]))
      refute has_element?(view, ~s(a[data-mobile-profile][aria-current="page"]))
    end

    test "Jobs stays active across the whole jobs section", %{conn: conn} do
      user = insert(:user)

      for path <- ["/jobs", "/jobs/some-posting-slug"] do
        {:ok, view, _html} =
          live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user, %{"path" => path}))

        assert has_element?(view, ~s(nav a[href="/jobs"][aria-current="page"]), "Jobs")
      end
    end

    test "the mobile tab bar marks the current tab active", %{conn: conn} do
      user = insert(:user)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive,
          session: session_for(user, %{"path" => "/messages"})
        )

      assert has_element?(view, ~s(nav a[href="/messages"][aria-current="page"]))
      refute has_element?(view, ~s(nav a[href="/search"][aria-current="page"]))
    end

    test "a look-alike slug does not activate a nav item (route boundary)", %{conn: conn} do
      user = insert(:user)

      # /jobsy merely BEGINS with "/jobs"; it is not the jobs section.
      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user, %{"path" => "/jobsy"}))

      refute has_element?(view, ~s(nav a[aria-current="page"]))
    end

    test "with no known path nothing is marked active", %{conn: conn} do
      user = insert(:user)
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

      refute has_element?(view, ~s(nav a[aria-current="page"]))
    end

    test "the real feed page marks the Feed nav item as current", %{conn: conn} do
      # End to end through the layout: the page must hand its path to the shell
      # (session "path") so the matching nav item is highlighted, and a sibling
      # page must not carry a stale highlight.
      {conn, _user} = create_and_login_user(conn)

      feed_doc = conn |> get(~p"/feed") |> html_response(200) |> LazyHTML.from_document()

      assert feed_doc
             |> LazyHTML.query(~s(nav a[href="/feed"][aria-current="page"]))
             |> Enum.any?()

      search_doc = conn |> get(~p"/search") |> html_response(200) |> LazyHTML.from_document()

      refute search_doc
             |> LazyHTML.query(~s(nav a[href="/feed"][aria-current="page"]))
             |> Enum.any?()
    end
  end

  describe "the Feed tab as a back-to-top control" do
    # On /feed the phone's Feed tab points at the page the member is already
    # reading, so once they have scrolled a screen down the useful press is
    # "back to the top", not a reload of what is under their thumb. The server
    # only lays the ground: it marks the tab (`data-scroll-top`, on the active
    # page alone) and renders the second glyph. `assets/js/scroll_top_tab.js`
    # sets `data-page-scrolled` on <html> once the page is a screen down, which
    # is both what swaps the glyph (components.css) and what the press handler
    # answers to — so the picture and the behaviour cannot disagree.

    test "on /feed the mobile Feed tab is marked and carries the arrow", %{conn: conn} do
      user = insert(:user)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user, %{"path" => "/feed"}))

      assert has_element?(view, ~s(nav[data-nav-bar="tabs"] a[href="/feed"][data-scroll-top]))
      assert has_element?(view, ~s(a[data-scroll-top] svg[data-tab-icon="feed"]))
      assert has_element?(view, ~s(a[data-scroll-top] svg[data-tab-icon="top"]))
    end

    # The arrow rests on an INLINE `display: none`, and that is a deploy
    # decision rather than a style one. A deploy reloads nothing: an open phone
    # keeps the previous release's CSS and the reconnecting socket patches this
    # new markup into it, so a glyph whose only "off" switch is a rule in the
    # new stylesheet would draw as a second icon crowding the Feed tab until the
    # member reloads — the shape the feed's tab ticker shipped in v7.347.0. An
    # inline style travels with the markup, so the old stylesheet needs to know
    # nothing, and it yields to the one `!important` rule in components.css. The
    # `hidden` attribute cannot do this job: preflight spells it
    # `display: none !important` inside `@layer base`, which no author rule can
    # lift (important declarations reverse the layer order and put unlayered
    # last), and the arrow measurably never appeared.
    test "the arrow ships hidden inline, so a pre-deploy stylesheet draws one glyph", %{
      conn: conn
    } do
      user = insert(:user)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user, %{"path" => "/feed"}))

      doc = view |> render() |> LazyHTML.from_fragment()

      assert [style] =
               doc
               |> LazyHTML.query(~s(a[data-scroll-top] svg[data-tab-icon="top"]))
               |> LazyHTML.attribute("style")

      assert style =~ ~r/display\s*:\s*none/

      # The feed glyph is the resting state and must not be hidden by anything.
      assert [] =
               doc
               |> LazyHTML.query(~s(a[data-scroll-top] svg[data-tab-icon="feed"]))
               |> LazyHTML.attribute("style")

      refute has_element?(view, ~s(a[data-scroll-top] svg[hidden]))
    end

    test "off the feed the Feed tab carries no back-to-top marker", %{conn: conn} do
      user = insert(:user)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive,
          session: session_for(user, %{"path" => "/search"})
        )

      refute has_element?(view, ~s(a[data-scroll-top]))
    end

    # The desktop bar is not a tab bar: its Feed item stays an ordinary link.
    # Counted rather than refuted, because both navs render an `a[href="/feed"]`
    # and the marker is what the press handler keys off — exactly one may carry
    # it, and the test above says which one that is.
    test "only the phone tab is a back-to-top control, not the desktop link", %{conn: conn} do
      user = insert(:user)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user, %{"path" => "/feed"}))

      marked =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(a[data-scroll-top]))

      assert Enum.count(marked) == 1
    end
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

  # The socket authenticates from the cookie's session_token, exactly like a
  # request (issue #1036). So a remotely logged-out device (issue #794) and a
  # suspended member drop the logged-in chrome on reconnect, and a captured,
  # signed shell_session map (which carries a bare user_id) can never be replayed
  # to render another member's chrome or leak their unread badge counts over the
  # "user:<id>" PubSub topic.
  describe "socket authentication (issue #1036)" do
    test "a revoked device drops to the anonymous shell with no badge", %{conn: conn} do
      user = user_with_unread_notification()
      {token, session} = Sessions.start_session(user, build_conn(), alert: false)
      Sessions.revoke(session)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: %{"session_token" => token})

      # No account menu, and crucially no unread badge: the shell never
      # subscribed to or counted this member's activity.
      assert has_element?(view, "a", "Log in")
      refute has_element?(view, "details[data-account-menu]")
      refute has_element?(view, @bell_badge)
    end

    test "a suspended member drops to the anonymous shell", %{conn: conn} do
      user = user_with_unread_notification()

      Repo.update_all(from(u in Vutuv.Accounts.User, where: u.id == ^user.id),
        set: [suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(:second), 86_400)]
      )

      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

      assert has_element?(view, "a", "Log in")
      refute has_element?(view, @bell_badge)
    end

    test "a replayed curated user_id without a token never authenticates", %{conn: conn} do
      # The core leak: a captured, signed shell_session map replayed alongside an
      # anonymous cookie must not render the member's chrome or leak their unread
      # badge counts.
      user = user_with_unread_notification()

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive,
          session: %{
            "user_id" => user.id,
            "user_name" => "Stefan Wintermeyer",
            "user_param" => "stefan"
          }
        )

      assert has_element?(view, "a", "Log in")
      refute has_element?(view, "details[data-account-menu]")
      refute has_element?(view, @bell_badge)
    end
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

  # The admin-only sign-up pulse: how many members confirmed their registration
  # so far on the current German calendar day. It shows only for an admin, only
  # when the figure is above zero, and follows along live.
  describe "new members today" do
    @pill "#new-members-today"

    # The admin pill is now gated on the resolved user's own admin flag (issue
    # #1036), not a curated session key, so the socket must resolve a real admin.
    defp admin_session(user), do: session_for(user)

    defp admin, do: insert(:user, admin?: true)

    defp joined_today(count) do
      {day_start, _} = Vutuv.BerlinTime.day_bounds_utc(Vutuv.BerlinTime.today())

      for _ <- 1..count,
          do: insert(:activated_user, inserted_at: day_start, updated_at: day_start)
    end

    test "shows today's confirmed sign-ups to an admin", %{conn: conn} do
      joined_today(2)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: admin_session(admin()))

      assert has_element?(view, @pill, "2")
    end

    test "stays hidden for a member who is not an admin", %{conn: conn} do
      joined_today(2)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: session_for(insert(:user)))

      refute has_element?(view, @pill)
    end

    test "stays hidden when nobody joined today", %{conn: conn} do
      {day_start, _} = Vutuv.BerlinTime.day_bounds_utc(Date.add(Vutuv.BerlinTime.today(), -1))
      insert(:activated_user, inserted_at: day_start, updated_at: day_start)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: admin_session(admin()))

      refute has_element?(view, @pill)
    end

    test "appears and counts up when a registration confirms", %{conn: conn} do
      # The shell only re-runs the query when the member half of the figure
      # actually MOVED against what it mounted with, and what it mounted with is
      # `PeopleCounter.counts()` — `:persistent_term`, which the SQL sandbox does
      # not roll back. So a figure typed in here ("1") differs from the mounted
      # one only by luck: on a run where something earlier had already put the
      # counter at 1, the shell correctly ignored the message and this test
      # failed, seed-dependently and nowhere near its cause. Count up from what
      # the socket really mounted with instead.
      mounted = Vutuv.PeopleCounter.counts()

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: admin_session(admin()))

      refute has_element?(view, @pill)

      # Vutuv.PeopleCounter broadcasts the new figures the moment a sign-up
      # confirms; the shell recomputes today's tally from the member half.
      joined_today(1)
      send(view.pid, {:people_count, moved(mounted, 1)})
      assert has_element?(view, @pill, "1")

      joined_today(1)
      send(view.pid, {:people_count, moved(mounted, 2)})
      assert has_element?(view, @pill, "2")
    end

    defp moved(%{members: members, fediverse: fediverse}, by) do
      %{members: members + by, fediverse: fediverse, total: members + by + fediverse}
    end

    test "names the exact figure in the viewer's language", %{conn: conn} do
      joined_today(1)
      session = admin_session(admin())

      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session)
      assert has_element?(view, ~s(#{@pill}[title="1 new member today"]))

      {:ok, german, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: Map.put(session, "locale", "de"))

      assert has_element?(german, ~s(#{@pill}[title="1 neues Mitglied heute"]))
    end

    test "renders at the nav's text size, not badge-small", %{conn: conn} do
      # The pill started life at text-xs and the figure was too small to read
      # at a glance. It sits between text-sm nav links, so it shares their size.
      joined_today(1)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: admin_session(admin()))

      assert has_element?(view, "#{@pill}.text-sm")
      refute has_element?(view, "#{@pill}.text-xs")
    end

    test "re-reads the figure at the Berlin day boundary", %{conn: conn} do
      joined_today(1)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: admin_session(admin()))

      assert has_element?(view, @pill, "1")

      # Vutuv.DayClock ticks at Berlin midnight, when yesterday's sign-ups stop
      # counting: the shell asks the (day-bounded) query again rather than
      # keeping the stale tally. Same fresh read, so a new member shows up too.
      joined_today(1)
      send(view.pid, :day_changed)
      assert has_element?(view, @pill, "2")
    end
  end

  describe "the people total in the top bar" do
    @total "#people-total"

    # The application-wide PeopleCounter is quiet in tests (its timers are off),
    # so the only `{:people_count, …}` on the topic is the one each test sends.
    defp broadcast_counts(members, fediverse \\ 0) do
      Phoenix.PubSub.broadcast(
        Vutuv.PubSub,
        "people_count",
        {:people_count, %{members: members, fediverse: fediverse, total: members + fediverse}}
      )
    end

    defp broadcast_total(n), do: broadcast_counts(n)

    test "ticks the exact total up when the counter broadcasts a new value", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: session_for(insert(:user)))

      broadcast_total(60_123)

      # The precise figure, not a compacted "60K" — a rounded total would never
      # visibly move, and watching it move is the point of the live counter.
      assert has_element?(view, @total, "60,123")

      broadcast_total(60_124)
      assert has_element?(view, @total, "60,124")
    end

    test "adds the Fediverse accounts to the members and explains the mixture", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: %{"locale" => "de"})

      # 5.508 members here and 412 distinct accounts following them from other
      # servers: one figure, because a reader asking how big this place is does
      # not care which side of the fence somebody stands on.
      broadcast_counts(5_508, 412)

      assert has_element?(view, @total, "5.920")

      # The breakdown rides the hover title and does not repeat the figure the
      # cursor is already on.
      assert has_element?(
               view,
               ~s(#{@total}[title="5.508 vutuv-Mitglieder plus 412 Fediverse-Accounts, die folgen"])
             )

      # The accessible name stays the plain total: an aria-label replaces the
      # element's own text for a screen reader, so the visible figure has to be
      # inside it (WCAG 2.5.3).
      assert has_element?(view, ~s(#{@total}[aria-label="5.920 Personen"]))
    end

    test "names a single Fediverse follower in the singular", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: %{"locale" => "de"})

      broadcast_counts(5_508, 1)

      assert has_element?(
               view,
               ~s(#{@total}[title="5.508 vutuv-Mitglieder plus 1 Fediverse-Account, der folgt"])
             )
    end

    test "keeps the plain label while nobody follows from the Fediverse", %{conn: conn} do
      # An installation with no remote followers (every intranet one, and this
      # one before it federated) would otherwise read "… and 0 accounts".
      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: %{"locale" => "de"})

      broadcast_counts(5_508, 0)

      assert has_element?(view, ~s(#{@total}[title="5.508 Personen"]))
    end

    test "shows the total to a logged-out visitor too", %{conn: conn} do
      # The people total is public (the landing page has advertised the figure
      # all along), so the chrome carries it whether or not anyone is signed in.
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})

      broadcast_total(60_123)

      assert has_element?(view, @total, "60,123")
    end

    test "groups the figure in the viewer's language", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: %{"locale" => "de"})

      broadcast_total(60_123)

      assert has_element?(view, @total, "60.123")
      assert has_element?(view, ~s(#{@total}[title="60.123 Personen"]))
    end

    test "links to the public member directory", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})

      broadcast_total(60_123)

      assert has_element?(view, ~s(#{@total}[href="/system/members"]))
    end

    test "stays hidden while the counter has no total yet", %{conn: conn} do
      # The cell reads 0 for the sub-second between boot and the first reconcile.
      # A "0 members" pill in the chrome would be worse than no pill at all.
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})

      broadcast_total(0)

      refute has_element?(view, @total)
    end

    # A glyph and a bare number read as a version string as easily as a head
    # count (reported 2026-08-01), so the word has to be on screen — but only
    # where the bar has room, and that depends on what else the bar is carrying
    # rather than on the breakpoint alone.
    test "spells out the word for a logged-out visitor at every width", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{"locale" => "de"})

      broadcast_total(60_123)

      assert has_element?(view, @total, "Personen")
      # No breakpoint gate for a visitor: their bar holds a wordmark, this pill
      # and a Log in button, with room to spare even on a phone. Asserted on the
      # word's own span — the pill's `md:hidden lg:inline-flex` contains the
      # substring "hidden lg:inline", so a plain text match passes for the wrong
      # reason.
      refute has_element?(view, "#{@total} span.hidden")
    end

    test "holds the word back until lg once a member's controls are in the bar", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: session_for(insert(:user)))

      broadcast_total(60_123)

      # Same word, but out of the way below lg: a signed-in bar also carries
      # search, bookmarks, messages, alerts and an avatar, and the documented
      # spare room below md was measured with exactly that.
      assert has_element?(view, "#{@total} span.hidden")
      assert has_element?(view, @total, "people")
    end

    # The figure arrives over PubSub while the reader is looking elsewhere, so a
    # changed total needs a cue; watching it move is the point of an exact live
    # count.
    test "the figure ticks when a new total arrives", %{conn: conn} do
      {:ok, view, html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})

      # Not on the first render: that would make every page load open with the
      # number sliding in, which reads as a page still loading.
      refute html =~ "people-total__figure--tick"

      broadcast_total(60_123)

      assert has_element?(view, "#{@total} span.people-total__figure--tick")
    end

    # LiveView patches text in place and a patched text node animates nothing,
    # so the figure's span has to be a NEW node for the animation to play.
    test "a changed total is a new node, not patched text", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})

      broadcast_total(60_123)
      assert has_element?(view, "#people-total-figure-60123")

      broadcast_total(60_124)
      assert has_element?(view, "#people-total-figure-60124")
      refute has_element?(view, "#people-total-figure-60123")
    end

    test "keeps the account controls at the right edge without it", %{conn: conn} do
      # The pill sits in an always-rendered middle cell of the header grid, so
      # the bar does not re-flow when the counter has nothing to show.
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})

      broadcast_total(0)

      assert has_element?(view, "#people-total-slot")
    end
  end
end
