defmodule VutuvWeb.SettingsControllerTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User

  describe "access control" do
    test "the settings pages render for the owner", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      for path <- [
            ~p"/#{user}/settings",
            ~p"/#{user}/settings/privacy",
            ~p"/#{user}/settings/notifications",
            ~p"/#{user}/settings/apps"
          ] do
        # Every settings page carries the shared sub-nav (so they are reachable
        # from one another); each one's own H1 is now its tab name, not the old
        # shared "Settings".
        assert conn |> recycle() |> get(path) |> html_response(200) =~
                 ~s(href="#{~p"/#{user}/settings/privacy"}")
      end
    end

    test "another member gets a 403", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      other = insert_activated_user()

      assert conn |> recycle() |> get(~p"/#{other}/settings") |> html_response(403)
      assert conn |> recycle() |> get(~p"/#{other}/settings/privacy") |> html_response(403)
      assert conn |> recycle() |> get(~p"/#{other}/settings/notifications") |> html_response(403)
      assert conn |> recycle() |> get(~p"/#{other}/settings/apps") |> html_response(403)
    end
  end

  describe "the settings sub-navigation" do
    test "the account hub links to all five tabs (Profile / Privacy / Notifications / Apps / Account)",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/settings") |> html_response(200)

      assert html =~ ~s(href="#{~p"/#{user}/edit"}")
      assert html =~ ~s(href="#{~p"/#{user}/settings/privacy"}")
      assert html =~ ~s(href="#{~p"/#{user}/settings/notifications"}")
      assert html =~ ~s(href="#{~p"/#{user}/settings/apps"}")
      assert html =~ ~s(href="#{~p"/#{user}/settings"}")
    end

    test "the profile editor carries the same sub-nav, so settings are reachable", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/edit") |> html_response(200)

      assert html =~ ~s(href="#{~p"/#{user}/settings/privacy"}")
      assert html =~ ~s(href="#{~p"/#{user}/settings/apps"}")
      assert html =~ ~s(href="#{~p"/#{user}/settings"}")
    end
  end

  describe "page titles" do
    # Each page owns its <title> so the browser tab/history no longer falls back
    # to the bare member name. The h1 names the tab (Account/Privacy/...); the
    # title is the longer "... settings" string, so matching it cannot collide
    # with the h1 or nav label.
    test "each settings and edit page sets its own page title", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      for {path, title} <- [
            {~p"/#{user}/edit", "Edit profile"},
            {~p"/#{user}/settings/privacy", "Privacy settings"},
            {~p"/#{user}/settings/notifications", "Notification settings"},
            {~p"/#{user}/settings/apps", "Apps &amp; API"},
            {~p"/#{user}/settings", "Account settings"}
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
      {conn, user} = create_and_login_user(conn)

      html = conn |> get(~p"/#{user}/settings/privacy") |> html_response(200)

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
        put(conn, ~p"/#{user}/settings/privacy",
          user: %{"noindex?" => "false", "noai?" => "false"}
        )

      assert redirected_to(conn) == ~p"/#{user}/settings/privacy"
      assert %{noindex?: false, noai?: false} = Repo.get(User, user.id)
    end

    test "unchecking both boxes stores opt-out (noindex?/noai? = true)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/#{user}/settings/privacy", user: %{"noindex?" => "true", "noai?" => "true"})

      assert redirected_to(conn) == ~p"/#{user}/settings/privacy"
      assert %{noindex?: true, noai?: true} = Repo.get(User, user.id)
    end
  end

  describe "privacy: safety card" do
    test "groups blocked members and content under review, both moved off the account hub",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/settings/privacy") |> html_response(200)

      assert html =~ ~s(href="#{~p"/blocks"}")
      assert html =~ ~s(href="#{~p"/moderation/cases"}")
    end
  end

  describe "privacy: online status" do
    # A positive flag (checked = shown), unlike the inverted robot switches:
    # checking submits "true", unchecking submits the hidden "false".

    test "the toggle shows on the privacy page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/settings/privacy") |> html_response(200)

      assert html =~ ~s(id="online-status-form")
      assert html =~ "show_online_status?"
    end

    test "unchecking opts the member out of the online dot", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      assert Repo.get(User, user.id).show_online_status? == true

      conn = put(conn, ~p"/#{user}/settings/privacy", user: %{"show_online_status?" => "false"})

      assert redirected_to(conn) == ~p"/#{user}/settings/privacy"
      assert Repo.get(User, user.id).show_online_status? == false
    end

    test "checking turns the online dot back on", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _} = Accounts.update_user(user, %{"show_online_status?" => "false"})

      conn = put(conn, ~p"/#{user}/settings/privacy", user: %{"show_online_status?" => "true"})

      assert redirected_to(conn) == ~p"/#{user}/settings/privacy"
      assert Repo.get(User, user.id).show_online_status? == true
    end

    test "saving broadcasts the new value so open shells start/stop the dot live", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      Vutuv.Activity.subscribe(user.id)

      put(conn, ~p"/#{user}/settings/privacy", user: %{"show_online_status?" => "false"})

      assert_receive {:presence_pref, false}
    end
  end

  describe "notifications: granular email toggles" do
    test "saving the per-type toggles persists each one and stays on the page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/#{user}/settings/notifications",
          user: %{
            "notification_emails?" => "false",
            "email_on_connection_request?" => "true",
            "email_on_endorsement?" => "true",
            "email_on_follower?" => "true"
          }
        )

      assert redirected_to(conn) == ~p"/#{user}/settings/notifications"

      assert %User{
               notification_emails?: false,
               email_on_connection_request?: true,
               email_on_endorsement?: true,
               email_on_follower?: true
             } = Repo.get(User, user.id)
    end

    test "the page offers a checkbox for every email type and links the bell", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/settings/notifications") |> html_response(200)

      assert html =~ "notification_emails?"
      assert html =~ "email_on_connection_request?"
      assert html =~ "email_on_endorsement?"
      assert html =~ "email_on_follower?"
      assert html =~ ~s(href="#{~p"/notifications"}")
    end
  end

  describe "account hub" do
    test "surfaces username, emails, language, data export and delete", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/settings") |> html_response(200)

      assert html =~ ~s(href="#{~p"/#{user}/usernames/new"}")
      assert html =~ ~s(href="#{~p"/#{user}/emails"}")
      assert html =~ ~s(href="#{~p"/#{user}/export"}")
      assert html =~ ~s(action="#{~p"/#{user}/settings/language"}")
      assert html =~ ~s(id="delete-account")
    end

    test "no longer carries blocking, moderation, or the developer apps/API rows", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/settings") |> html_response(200)

      # Blocking + moderation moved to Privacy; apps/tokens/API moved to Apps.
      refute html =~ ~s(href="#{~p"/blocks"}")
      refute html =~ ~s(href="#{~p"/moderation/cases"}")
      refute html =~ ~s(href="#{~p"/connected_apps"}")
      refute html =~ ~s(href="#{~p"/access_tokens"}")
    end
  end

  describe "apps tab" do
    test "surfaces connected apps, access tokens and the API docs cross-link", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/settings/apps") |> html_response(200)

      assert html =~ ~s(href="#{~p"/connected_apps"}")
      assert html =~ ~s(href="#{~p"/access_tokens"}")
      assert html =~ ~s(href="#{~p"/developers"}")
    end
  end

  describe "interface language" do
    test "saving the language persists locale and stays on the account hub", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = put(conn, ~p"/#{user}/settings/language", user: %{"locale" => "de"})

      assert redirected_to(conn) == ~p"/#{user}/settings"
      assert Repo.get(User, user.id).locale == "de"
    end
  end

  describe "map preferences" do
    test "the account hub offers the maps form with every service and the default", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/settings") |> html_response(200)

      assert html =~ ~s(action="#{~p"/#{user}/settings/maps"}")
      assert html =~ "map_google?"
      assert html =~ "map_openstreetmap?"
      assert html =~ "map_apple?"
      assert html =~ "default_map_service"
    end

    test "saving persists the enabled services and the default, and stays on the hub", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/#{user}/settings/maps",
          user: %{
            "map_google?" => "true",
            "map_openstreetmap?" => "false",
            "map_apple?" => "true",
            "default_map_service" => "apple"
          }
        )

      assert redirected_to(conn) == ~p"/#{user}/settings"

      assert %User{
               map_google?: true,
               map_openstreetmap?: false,
               map_apple?: true,
               default_map_service: "apple"
             } = Repo.get(User, user.id)
    end

    test "an unknown default is rejected by the changeset", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = put(conn, ~p"/#{user}/settings/maps", user: %{"default_map_service" => "bing"})

      assert html_response(conn, 422)
      assert Repo.get(User, user.id).default_map_service == "google"
    end
  end
end
