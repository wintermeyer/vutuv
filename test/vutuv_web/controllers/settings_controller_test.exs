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
            ~p"/settings/export",
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

  describe "the settings hub" do
    # The hub is the one map of everything a member can change about
    # themselves: profile content, account matters, privacy, notifications,
    # apps and the delete exit. If it is not on the hub, it does not exist.
    test "lists every editable area", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings") |> html_response(200)

      # Profile content sections.
      assert html =~ ~s(href="#{~p"/settings/profile"}")
      assert html =~ ~s(href="#{~p"/settings/work_experiences"}")
      assert html =~ ~s(href="#{~p"/settings/educations"}")
      assert html =~ ~s(href="#{~p"/settings/links"}")
      assert html =~ ~s(href="#{~p"/settings/social_media_accounts"}")
      assert html =~ ~s(href="#{~p"/settings/emails"}")
      assert html =~ ~s(href="#{~p"/settings/phone_numbers"}")
      assert html =~ ~s(href="#{~p"/settings/addresses"}")
      assert html =~ ~s(href="#{~p"/settings/tags"}")
      # Account subpages (split off the old mega-page).
      assert html =~ ~s(href="#{~p"/settings/security"}")
      assert html =~ ~s(href="#{~p"/settings/preferences"}")
      assert html =~ ~s(href="#{~p"/settings/import/linkedin"}")
      assert html =~ ~s(href="#{~p"/settings/export"}")
      # The rest.
      assert html =~ ~s(href="#{~p"/settings/privacy"}")
      assert html =~ ~s(href="#{~p"/settings/notifications"}")
      assert html =~ ~s(href="#{~p"/settings/apps"}")
      assert html =~ ~s(href="#{~p"/settings/delete"}")
    end

    test "shows a live count for the profile content sections", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert_list(2, :work_experience, user: user)
      insert(:url, user: user)

      html = conn |> get(~p"/settings") |> html_response(200)

      assert html =~ ~s(<span data-hub-count="work">2</span>)
      assert html =~ ~s(<span data-hub-count="links">1</span>)
      assert html =~ ~s(<span data-hub-count="education">0</span>)
    end

    test "the hub itself carries no destructive control, only the door to it", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings") |> html_response(200)

      # Deleting starts on its own page, never straight from the hub row.
      refute html =~ ~s(id="delete-account")
      assert html =~ ~s(href="#{~p"/settings/delete"}")
    end
  end

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
            {~p"/settings/privacy", "Privacy settings"},
            {~p"/settings/notifications", "Notification settings"},
            {~p"/settings/apps", "Apps &amp; API"},
            {~p"/settings", "Settings"},
            {~p"/settings/security", "Sign-in &amp; security"},
            {~p"/settings/preferences", "Language &amp; maps"},
            {~p"/settings/export", "Export"},
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

      assert html =~ ~s(id="mastodon-feed-form")
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
    test "surfaces username, email addresses, devices and passkeys", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/security") |> html_response(200)

      assert html =~ ~s(href="#{~p"/settings/usernames/new"}")
      assert html =~ ~s(href="#{~p"/settings/emails"}")
      # The device list (this test session is a signed-in device).
      assert html =~ "Last active"
      # The passkey enrol block.
      assert html =~ "data-webauthn-register"
    end
  end

  describe "language & maps page" do
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
  end

  describe "export page" do
    test "explains the download and offers it as a button", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/export") |> html_response(200)

      assert html =~ "data-settings-shell"
      assert html =~ ~s(href="#{~p"/settings/export/download"}")
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
      assert Repo.get(User, user.id).default_map_service == "google"
    end
  end
end
