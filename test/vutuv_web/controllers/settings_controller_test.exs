defmodule VutuvWeb.SettingsControllerTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User

  describe "access control" do
    test "the settings pages render for the owner", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      for path <- [
            ~p"/settings",
            ~p"/settings/privacy",
            ~p"/settings/notifications",
            ~p"/settings/apps",
            ~p"/settings/security",
            ~p"/settings/preferences",
            ~p"/settings/delete"
          ] do
        # Every settings page carries a way to every other settings area (the
        # hub lists them; the subpages carry the sidebar), so they are always
        # reachable from one another.
        assert conn |> recycle() |> get(path) |> html_response(200) =~
                 ~s(href="#{~p"/settings/privacy"}")
      end
    end

    test "logged out, every settings page requires a login", %{conn: conn} do
      for path <- [~p"/settings", ~p"/settings/privacy", ~p"/settings/delete"] do
        assert conn |> recycle() |> get(path) |> redirected_to() == "/"
      end
    end

    test "the old slug-based settings URLs redirect into /settings", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      assert conn |> recycle() |> get("/#{user.username}/settings") |> redirected_to() ==
               "/settings"

      assert conn |> recycle() |> get("/#{user.username}/settings/privacy") |> redirected_to() ==
               "/settings/privacy"

      assert conn |> recycle() |> get("/#{user.username}/edit") |> redirected_to() ==
               "/settings/profile"
    end
  end

  # The hub itself — its grouping, its rows, the search box and the entry
  # counts — is covered by VutuvWeb.SettingsHubTest, which asserts against
  # settings_menu/1 directly instead of a hand-kept list of paths.

  describe "the profile editor (/edit)" do
    test "links every other profile section, so it is no dead end", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/profile") |> html_response(200)

      for path <- [
            ~p"/settings/work_experiences",
            ~p"/settings/educations",
            ~p"/settings/links",
            ~p"/settings/social_media_accounts",
            ~p"/settings/emails",
            ~p"/settings/phone_numbers",
            ~p"/settings/addresses",
            ~p"/settings/tags"
          ] do
        assert html =~ ~s(href="#{path}")
      end
    end

    test "carries the way back to the hub and the cover-photo anchor", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/profile") |> html_response(200)

      assert html =~ ~s(href="#{~p"/settings"}")
      assert html =~ ~s(id="cover")
    end
  end

  describe "page titles" do
    # Each page owns its <title> so the browser tab/history no longer falls back
    # to the bare member name.
    test "each settings and edit page sets its own page title", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      for {path, title} <- [
            {~p"/settings/profile", "Edit profile"},
            {~p"/settings/social_media_accounts", "Profiles"},
            {~p"/settings/privacy", "Visibility"},
            {~p"/settings/username", "Username"},
            {~p"/settings/notifications", "Notification settings"},
            {~p"/settings/apps", "Apps &amp; API"},
            {~p"/settings", "Settings"},
            {~p"/settings/security", "Sign-in &amp; security"},
            {~p"/settings/preferences", "Language &amp; display"},
            {~p"/settings/delete", "Delete account"}
          ] do
        html = conn |> recycle() |> get(path) |> html_response(200)
        assert html =~ "<title" and html =~ title
      end
    end
  end

  describe "privacy: search engines & AI" do
    # The boxes are framed positively ("Allow …") but the fields are the
    # opt-out noindex?/noai?, so a CHECKED box submits "false" (allow) and an
    # UNCHECKED box submits the hidden "true" (opt out).

    test "the card explains the opt-out in plain terms, with exact specifics for the technical reader",
         %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings/privacy") |> html_response(200)

      # Plain-language nuance for the layperson (no jargon): a public page can
      # still be read, but we tell engines/AI we do not want it, and the
      # reputable ones comply.
      assert html =~ "the machine-readable way they look for"
      assert html =~ "Reputable search engines and AI companies follow that request"
      # The technical reader gets the exact directives as a copy-and-read
      # example, not just prose.
      assert html =~ "X-Robots-Tag: noindex, noai, noimageai"
      assert html =~ "Content-Signal: ai-train=no, search=no, ai-input=no"
      assert html =~ "out of the sitemap and structured data"
      # Each checkbox spells out what turning it off actually does.
      assert html =~ "we ask them to leave it out"
      assert html =~ "we ask them not to"
    end

    test "checking both boxes stores allow (noindex?/noai? = false)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _} = Accounts.update_user(user, %{"noindex?" => "true", "noai?" => "true"})

      conn =
        put(conn, ~p"/settings/privacy", user: %{"noindex?" => "false", "noai?" => "false"})

      assert redirected_to(conn) == ~p"/settings/privacy"
      assert %{noindex?: false, noai?: false} = Repo.get(User, user.id)
    end

    test "unchecking both boxes stores opt-out (noindex?/noai? = true)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/settings/privacy", user: %{"noindex?" => "true", "noai?" => "true"})

      assert redirected_to(conn) == ~p"/settings/privacy"
      assert %{noindex?: true, noai?: true} = Repo.get(User, user.id)
    end
  end

  describe "privacy: safety card" do
    test "groups blocked members and content under review", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/privacy") |> html_response(200)

      assert html =~ ~s(href="#{~p"/blocks"}")
      assert html =~ ~s(href="#{~p"/moderation/cases"}")
    end
  end

  describe "privacy: online status" do
    # A positive flag (checked = shown), unlike the inverted robot switches:
    # checking submits "true", unchecking submits the hidden "false".

    test "the toggle shows on the privacy page", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/privacy") |> html_response(200)

      assert html =~ ~s(id="online-status-form")
      assert html =~ "show_online_status?"
    end

    test "unchecking opts the member out of the online dot", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      assert Repo.get(User, user.id).show_online_status? == true

      conn = put(conn, ~p"/settings/privacy", user: %{"show_online_status?" => "false"})

      assert redirected_to(conn) == ~p"/settings/privacy"
      assert Repo.get(User, user.id).show_online_status? == false
    end

    test "checking turns the online dot back on", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _} = Accounts.update_user(user, %{"show_online_status?" => "false"})

      conn = put(conn, ~p"/settings/privacy", user: %{"show_online_status?" => "true"})

      assert redirected_to(conn) == ~p"/settings/privacy"
      assert Repo.get(User, user.id).show_online_status? == true
    end

    test "saving broadcasts the new value so open shells start/stop the dot live", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      Vutuv.Activity.subscribe(user.id)

      put(conn, ~p"/settings/privacy", user: %{"show_online_status?" => "false"})

      assert_receive {:presence_pref, false}
    end
  end

  describe "privacy: Mastodon posts" do
    # A positive flag like the online dot: default on, unchecking opts out of
    # the inline Mastodon posts on the profile's Social Media card.

    test "the toggle shows on the privacy page", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/privacy") |> html_response(200)

      assert html =~ ~s(id="social-feed-form")
      assert html =~ "show_mastodon_feed?"
    end

    test "unchecking hides the Mastodon posts from the profile", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      assert Repo.get(User, user.id).show_mastodon_feed? == true

      conn = put(conn, ~p"/settings/privacy", user: %{"show_mastodon_feed?" => "false"})

      assert redirected_to(conn) == ~p"/settings/privacy"
      assert Repo.get(User, user.id).show_mastodon_feed? == false
    end

    test "checking shows them again", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _} = Accounts.update_user(user, %{"show_mastodon_feed?" => "false"})

      conn = put(conn, ~p"/settings/privacy", user: %{"show_mastodon_feed?" => "true"})

      assert redirected_to(conn) == ~p"/settings/privacy"
      assert Repo.get(User, user.id).show_mastodon_feed? == true
    end
  end

  # The main Fediverse page answers one question — do I take part at all — for a
  # member who has never heard the word. Account migration is an expert affair
  # and lives on /settings/fediverse/move, so none of its controls may leak back
  # onto the main page (that mix is what the split fixed).
  test "fediverse: the main page carries no account-migration controls at all", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, _} = Accounts.update_user(user, %{"fediverse_followers?" => "true"})

    html = conn |> get(~p"/settings/fediverse") |> html_response(200)

    refute html =~ ~s(id="user_also_known_as_input")
    refute html =~ ~s(id="move-form")
    # It links there instead.
    assert html =~ ~s(href="#{~p"/settings/fediverse/move"}")
  end

  test "fediverse: the migration link only shows once the member federates", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    refute conn |> get(~p"/settings/fediverse") |> html_response(200) =~
             ~s(href="#{~p"/settings/fediverse/move"}")
  end

  test "fediverse: the migration page redirects a member who does not federate", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    conn = get(conn, ~p"/settings/fediverse/move")

    assert redirected_to(conn) == ~p"/settings/fediverse"
  end

  describe "fediverse: reaction counts from other networks (#1068)" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, user} = Accounts.update_user(user, %{"fediverse_followers?" => "true"})
      %{conn: conn, user: user}
    end

    test "the switch shows once federation is on, and is on by default", %{
      conn: conn,
      user: user
    } do
      assert user.fediverse_reactions?

      html = conn |> get(~p"/settings/fediverse") |> html_response(200)

      assert html =~ ~s(name="user[fediverse_reactions?]")
      assert html =~ "Show reactions from other networks"
      # The copy has to stay true to the line under the post, which names the
      # accounts rather than merely counting them.
      assert html =~ "who out there liked or shared it"
    end

    test "the switch is hidden until the member federates", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user(user, %{"fediverse_followers?" => "false"})

      html = conn |> get(~p"/settings/fediverse") |> html_response(200)

      refute html =~ ~s(name="user[fediverse_reactions?]")
    end

    test "switching it off deletes what is already stored", %{conn: conn, user: user} do
      post = Vutuv.PostsHelpers.create_post!(user, %{body: "Travelled far."})

      Repo.insert!(%Vutuv.Fediverse.Reaction{
        post_id: post.id,
        actor_uri: "https://social.example/users/alice",
        kind: "like",
        received_at: DateTime.utc_now(:second)
      })

      conn =
        put(conn, ~p"/settings/fediverse",
          user: %{"fediverse_followers?" => "true", "fediverse_reactions?" => "false"}
        )

      assert redirected_to(conn) == ~p"/settings/fediverse"
      refute Repo.get(User, user.id).fediverse_reactions?
      assert Repo.aggregate(Vutuv.Fediverse.Reaction, :count) == 0
    end
  end

  # Both directions of the take-part switch are unreversible in ways nobody can
  # fix afterwards, so neither flips until the member says they understood.
  describe "fediverse: the take-part switch asks first (#1072)" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "the page carries the acknowledgement field and both dialogs", %{conn: conn} do
      html = conn |> get(~p"/settings/fediverse") |> html_response(200)

      assert html =~ ~s(data-fediverse-ack)
      assert html =~ ~s(id="fediverse-consent-on")
      assert html =~ ~s(id="fediverse-consent-off")
      assert html =~ "out of our hands"
    end

    test "switching on without the acknowledgement asks instead of saving", %{
      conn: conn,
      user: user
    } do
      conn = put(conn, ~p"/settings/fediverse", user: %{"fediverse_followers?" => "true"})

      html = html_response(conn, 200)
      assert html =~ "out of our hands"
      assert html =~ "I understand, take part"
      refute Repo.get(User, user.id).fediverse_followers?
    end

    test "the acknowledged submit saves and mints the actor", %{conn: conn, user: user} do
      conn =
        put(conn, ~p"/settings/fediverse",
          user: %{"fediverse_followers?" => "true"},
          fediverse_ack: "1"
        )

      assert redirected_to(conn) == ~p"/settings/fediverse"
      saved = Repo.get(User, user.id)
      assert saved.fediverse_followers?
      assert Vutuv.Fediverse.get_actor(saved)
    end

    test "switching off asks with the words for leaving, then drops the remote followers",
         %{conn: conn, user: user} do
      {:ok, user} = Accounts.update_user(user, %{"fediverse_followers?" => "true"})
      {:ok, _actor} = Vutuv.Fediverse.ensure_actor(user)

      {:ok, _} =
        Vutuv.Fediverse.add_follower(user, %{
          actor_uri: "https://social.example/users/alice",
          inbox_uri: "https://social.example/inbox"
        })

      asked =
        put(conn, ~p"/settings/fediverse", user: %{"fediverse_followers?" => "false"})

      html = html_response(asked, 200)
      assert html =~ "does not delete what is already out there"
      assert html =~ "I understand, switch off"
      assert Repo.get(User, user.id).fediverse_followers?
      assert Vutuv.Fediverse.follower_count(user) == 1

      confirmed =
        put(recycle(conn), ~p"/settings/fediverse",
          user: %{"fediverse_followers?" => "false"},
          fediverse_ack: "1"
        )

      assert redirected_to(confirmed) == ~p"/settings/fediverse"
      refute Repo.get(User, user.id).fediverse_followers?

      # The actor answers 410 from now on, so those servers drop the follow at
      # their end too — a kept row would be a relationship that exists nowhere.
      assert Vutuv.Fediverse.follower_count(user) == 0
    end
  end

  describe "fediverse: alsoKnownAs account migration (#986)" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, user} = Accounts.update_user(user, %{"fediverse_followers?" => "true"})
      %{conn: conn, user: user}
    end

    test "both directions live on the migration subpage, named as a pair", %{conn: conn} do
      html = conn |> get(~p"/settings/fediverse/move") |> html_response(200)

      # Moving in (the aliases) and moving out (the Move) side by side, each
      # labelled with its direction — apart on one long page they read alike.
      assert html =~ ~s(id="user_also_known_as_input")
      assert html =~ ~s(id="move-form")
      assert html =~ "Moving to vutuv"
      assert html =~ "Moving away from vutuv"
      # The rendered form targets, not routes a test knows exist.
      assert html =~ ~s(action="#{~p"/settings/fediverse/move"}")
    end

    test "saving records the listed accounts, one per line", %{conn: conn, user: user} do
      conn =
        put(conn, ~p"/settings/fediverse/move",
          user: %{
            "also_known_as_input" =>
              "https://mastodon.social/users/alice\nhttps://fosstodon.org/users/alice\n"
          }
        )

      assert redirected_to(conn) == ~p"/settings/fediverse/move"

      assert Repo.get(User, user.id).also_known_as == [
               "https://mastodon.social/users/alice",
               "https://fosstodon.org/users/alice"
             ]
    end

    test "the stored accounts are seeded back into the textarea", %{conn: conn, user: user} do
      {:ok, _} =
        Accounts.update_user(user, %{
          "also_known_as_input" => "https://mastodon.social/users/alice"
        })

      html = conn |> get(~p"/settings/fediverse/move") |> html_response(200)

      assert html =~ "https://mastodon.social/users/alice"
    end

    test "a non-https entry is rejected without changing the stored list", %{
      conn: conn,
      user: user
    } do
      {:ok, _} =
        Accounts.update_user(user, %{
          "also_known_as_input" => "https://mastodon.social/users/alice"
        })

      conn =
        put(conn, ~p"/settings/fediverse/move", user: %{"also_known_as_input" => "not-a-url"})

      assert html_response(conn, 422) =~ "not a valid https account address"
      assert Repo.get(User, user.id).also_known_as == ["https://mastodon.social/users/alice"]
    end

    # Move-out rendering + cancel only (no HTTP stub, so this async module never
    # touches :fediverse_req_options). The Move broadcast itself is covered by
    # Vutuv.FediverseTest (async: false).
    test "the move-out form points at the move route while not moved", %{conn: conn} do
      html = conn |> get(~p"/settings/fediverse/move") |> html_response(200)

      assert html =~ ~s(id="move-form")
      assert html =~ ~s(action="#{~p"/settings/fediverse/move"}")
      # No redirect banner while the member has not moved.
      refute html =~ "cancel-move-form"
    end

    test "once moved, the page shows the redirect and a cancel control, not the move-out form",
         %{conn: conn, user: user} do
      {:ok, _} =
        user
        |> Ecto.Changeset.change(moved_to: "https://mastodon.social/users/gone")
        |> Repo.update()

      html = conn |> get(~p"/settings/fediverse/move") |> html_response(200)

      assert html =~ "https://mastodon.social/users/gone"
      assert html =~ ~s(id="cancel-move-form")
      refute html =~ ~s(id="move-form")
    end

    test "cancelling the move clears the redirect", %{conn: conn, user: user} do
      {:ok, _} =
        user
        |> Ecto.Changeset.change(moved_to: "https://mastodon.social/users/gone")
        |> Repo.update()

      conn = delete(conn, ~p"/settings/fediverse/move")

      # Back to the migration page, where the state change is on screen.
      assert redirected_to(conn) == ~p"/settings/fediverse/move"
      assert Repo.get(User, user.id).moved_to == nil
    end
  end

  describe "notifications: granular email toggles" do
    test "saving the per-type toggles persists each one and stays on the page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/settings/notifications",
          user: %{
            "notification_emails?" => "false",
            "email_on_endorsement?" => "true",
            "email_on_follower?" => "true"
          }
        )

      assert redirected_to(conn) == ~p"/settings/notifications"

      assert %User{
               notification_emails?: false,
               email_on_endorsement?: true,
               email_on_follower?: true
             } = Repo.get(User, user.id)
    end

    test "the page offers a checkbox for every email type and links the bell", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/notifications") |> html_response(200)

      assert html =~ "notification_emails?"
      # The connection-request opt-in is gone (no request flow any more).
      refute html =~ "email_on_connection_request?"
      assert html =~ "email_on_endorsement?"
      assert html =~ "email_on_follower?"
      # The unread-message frequency and delay controls.
      assert html =~ "dm_email_each_message?"
      assert html =~ "dm_email_delay_minutes"
      assert html =~ ~s(href="#{~p"/notifications"}")
      # The two in-app opt-outs (issue #980 CV updates, issue #1025 threads).
      assert html =~ "cv_update_notifications?"
      assert html =~ "thread_notifications?"
    end

    test "switching thread notifications off persists (issue #1025)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/settings/notifications", user: %{"thread_notifications?" => "false"})

      assert redirected_to(conn) == ~p"/settings/notifications"
      assert %User{thread_notifications?: false} = Repo.get(User, user.id)
    end

    test "saving the message-email frequency and delay persists them", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/settings/notifications",
          user: %{
            "notification_emails?" => "true",
            "dm_email_each_message?" => "true",
            "dm_email_delay_minutes" => "30"
          }
        )

      assert redirected_to(conn) == ~p"/settings/notifications"

      assert %User{dm_email_each_message?: true, dm_email_delay_minutes: 30} =
               Repo.get(User, user.id)
    end

    test "an unsupported delay value is rejected and nothing is saved", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/settings/notifications", user: %{"dm_email_delay_minutes" => "7"})

      assert html_response(conn, 422)
      assert Repo.get(User, user.id).dm_email_delay_minutes == 15
    end
  end

  describe "sign-in & security page" do
    test "surfaces email addresses, devices and passkeys", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/security") |> html_response(200)

      assert html =~ ~s(href="#{~p"/settings/emails"}")
      # The device list (this test session is a signed-in device).
      assert html =~ "Last active"
      # The passkey enrol block.
      assert html =~ "data-webauthn-register"
    end

    test "hands the username on instead of holding it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/security") |> html_response(200)

      # The handle and the permanent profile link are public identity, not
      # credentials, so they live on /settings/username under Profile now.
      # This page keeps a signpost for whoever still looks here first.
      assert html =~ ~s(href="#{~p"/settings/username"}")
      refute html =~ ~s(id="permalink-url")
      refute html =~ url(~p"/system/permalinks/users/#{user.id}")
    end
  end

  describe "the permanent profile link (issue #904)" do
    test "sits on the username page, with a copy button on both addresses", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/username") |> html_response(200)

      # The username-independent permalink URL, built from the fixed id, and
      # the everyday address it is the durable twin of.
      assert html =~ url(~p"/system/permalinks/users/#{user.id}")
      assert html =~ url(~p"/#{user}")

      # Each <code> carries the id its copy button targets, and the buttons are
      # wired for the [data-copy] app.js enhancement.
      assert html =~ ~s(id="permalink-url")
      assert html =~ ~s(data-copy-target="permalink-url")
      assert html =~ ~s(id="profile-url")
      assert html =~ ~s(data-copy-target="profile-url")
    end

    test "reads after the rename form, as the answer to 'my old links break'", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/username") |> html_response(200)

      {rename, _} = :binary.match(html, "Change your username")
      {permalink, _} = :binary.match(html, "Permanent profile link")
      assert permalink > rename
    end
  end

  describe "language & display page" do
    test "carries the interface-language and map-preference forms", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/preferences") |> html_response(200)

      assert html =~ ~s(action="#{~p"/settings/language"}")
      assert html =~ ~s(action="#{~p"/settings/maps"}")
      assert html =~ "map_google?"
      assert html =~ "map_openstreetmap?"
      assert html =~ "map_apple?"
      assert html =~ "default_map_service"
    end

    test "carries the post-display form with the line and hyphenation fields", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/preferences") |> html_response(200)

      # Assert the rendered action= so the button is not posting to a dead URL.
      assert html =~ ~s(action="#{~p"/settings/post_display"}")
      assert html =~ "post_lines_desktop"
      assert html =~ "post_lines_mobile"
      assert html =~ "post_hyphenate_desktop"
      assert html =~ "post_hyphenate_mobile"
      assert html =~ "notification_post_lines"
    end
  end

  describe "post-display preferences" do
    test "saving persists the line counts and hyphenation, and stays on the page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/settings/post_display",
          user: %{
            "post_lines_desktop" => "4",
            "post_lines_mobile" => "0",
            "post_hyphenate_desktop" => "true",
            "post_hyphenate_mobile" => "false"
          }
        )

      assert redirected_to(conn) == ~p"/settings/preferences"

      assert %User{
               post_lines_desktop: 4,
               post_lines_mobile: 0,
               post_hyphenate_desktop: true,
               post_hyphenate_mobile: false
             } = Repo.get(User, user.id)
    end

    test "a blank line field saves as 0 (no truncation)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = put(conn, ~p"/settings/post_display", user: %{"post_lines_desktop" => ""})

      assert redirected_to(conn) == ~p"/settings/preferences"
      assert Repo.get(User, user.id).post_lines_desktop == 0
    end

    test "an out-of-range line count re-renders the page with an error", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      conn = put(conn, ~p"/settings/post_display", user: %{"post_lines_desktop" => "999"})

      assert html_response(conn, 422) =~ ~s(action="#{~p"/settings/post_display"}")
    end

    test "the notification line count saves on the same form", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = put(conn, ~p"/settings/post_display", user: %{"notification_post_lines" => "3"})

      assert redirected_to(conn) == ~p"/settings/preferences"
      assert Repo.get(User, user.id).notification_post_lines == 3
    end

    test "a blank notification line field goes back to inheriting the site default", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = put(conn, ~p"/settings/post_display", user: %{"notification_post_lines" => "3"})

      conn =
        put(recycle(conn), ~p"/settings/post_display", user: %{"notification_post_lines" => ""})

      assert redirected_to(conn) == ~p"/settings/preferences"
      # nil, not 0: a notification quote is always cut, so there is no
      # "never shorten" value to fall back on.
      assert Repo.get(User, user.id).notification_post_lines == nil
    end

    test "a notification line count below the floor re-renders with an error", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      conn = put(conn, ~p"/settings/post_display", user: %{"notification_post_lines" => "0"})

      assert html_response(conn, 422) =~ ~s(action="#{~p"/settings/post_display"}")
    end
  end

  describe "export redirects" do
    # The export area lives under the profile now (/:slug/export, issue
    # #841); the settings-era URLs keep working as redirects.
    test "the old /settings/export URLs redirect to the profile's export corner",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      assert conn |> recycle() |> get("/settings/export") |> redirected_to() ==
               "/#{user.username}/export"

      assert conn |> recycle() |> get("/settings/export/download") |> redirected_to() ==
               "/#{user.username}/export/download"
    end

    test "the old /settings/data URL redirects to the hub", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert conn |> get("/settings/data") |> redirected_to() == "/settings"
    end
  end

  describe "import page" do
    test "renders inside the settings shell", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/import/linkedin") |> html_response(200)

      assert html =~ "data-settings-shell"
      assert html =~ "linkedin-import-form"
    end
  end

  describe "delete account page" do
    test "carries the warning and the PIN-mailing delete control", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/delete") |> html_response(200)

      assert html =~ ~s(id="delete-account")
      assert html =~ "It cannot be undone"
    end
  end

  describe "apps tab" do
    test "surfaces connected apps, access tokens and the API docs cross-link", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/apps") |> html_response(200)

      assert html =~ ~s(href="#{~p"/connected_apps"}")
      assert html =~ ~s(href="#{~p"/access_tokens"}")
      assert html =~ ~s(href="#{~p"/developers"}")
    end
  end

  describe "interface language" do
    test "saving the language persists locale and stays on the preferences page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = put(conn, ~p"/settings/language", user: %{"locale" => "de"})

      assert redirected_to(conn) == ~p"/settings/preferences"
      assert Repo.get(User, user.id).locale == "de"
    end
  end

  describe "map preferences" do
    test "saving persists the enabled services and the default, and stays on the preferences page",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/settings/maps",
          user: %{
            "map_google?" => "true",
            "map_openstreetmap?" => "false",
            "map_apple?" => "true",
            "default_map_service" => "apple"
          }
        )

      assert redirected_to(conn) == ~p"/settings/preferences"

      assert %User{
               map_google?: true,
               map_openstreetmap?: false,
               map_apple?: true,
               default_map_service: "apple"
             } = Repo.get(User, user.id)
    end

    test "an unknown default is rejected by the changeset", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = put(conn, ~p"/settings/maps", user: %{"default_map_service" => "bing"})

      assert html_response(conn, 422)
      # Still nil = "inherit the installation default" (Vutuv.Prefs); the
      # rejected value must not have been stored.
      assert Repo.get(User, user.id).default_map_service == nil
    end
  end

  # Muted words & tags (issue #940): the member's private content filter.
  describe "content filters (#940)" do
    test "the page lists the member's filters and offers the add form", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, _} =
        Vutuv.ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "crypto"})

      html = conn |> get(~p"/settings/filters") |> html_response(200)

      assert html =~ "crypto"
      assert html =~ ~s(id="content-filter-form")
    end

    test "adding a filter persists it and stays on the page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/settings/filters",
          content_filter: %{"kind" => "keyword", "pattern" => "crypto*", "whole_word" => "false"}
        )

      assert redirected_to(conn) == ~p"/settings/filters"
      assert [%{pattern: "crypto*", whole_word: false}] = Vutuv.ContentFilters.list_for_user(user)
    end

    test "a wildcard-only pattern is rejected with a 422", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/settings/filters",
          content_filter: %{"kind" => "keyword", "pattern" => "***"}
        )

      assert html_response(conn, 422)
      assert Vutuv.ContentFilters.list_for_user(user) == []
    end

    test "deleting removes the filter", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, filter} =
        Vutuv.ContentFilters.create_filter(user, %{"kind" => "tag", "pattern" => "politics"})

      conn = delete(conn, ~p"/settings/filters/#{filter.id}")

      assert redirected_to(conn) == ~p"/settings/filters"
      assert Vutuv.ContentFilters.list_for_user(user) == []
    end

    test "the filters row is on the settings hub", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings") |> html_response(200)

      assert html =~ ~s(href="#{~p"/settings/filters"}")
    end
  end
end
