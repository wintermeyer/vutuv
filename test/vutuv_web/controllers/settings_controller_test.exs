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
            ~p"/#{user}/settings/notifications"
          ] do
        assert conn |> recycle() |> get(path) |> html_response(200) =~ "Settings"
      end
    end

    test "another member gets a 403", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      other = insert_activated_user()

      assert conn |> recycle() |> get(~p"/#{other}/settings") |> html_response(403)
      assert conn |> recycle() |> get(~p"/#{other}/settings/privacy") |> html_response(403)
      assert conn |> recycle() |> get(~p"/#{other}/settings/notifications") |> html_response(403)
    end
  end

  describe "the settings sub-navigation" do
    test "the account hub links to all four tabs (Profile / Privacy / Notifications / Account)",
         %{
           conn: conn
         } do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/settings") |> html_response(200)

      assert html =~ ~s(href="#{~p"/#{user}/edit"}")
      assert html =~ ~s(href="#{~p"/#{user}/settings/privacy"}")
      assert html =~ ~s(href="#{~p"/#{user}/settings/notifications"}")
      assert html =~ ~s(href="#{~p"/#{user}/settings"}")
    end

    test "the profile editor carries the same sub-nav, so settings are reachable", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/edit") |> html_response(200)

      assert html =~ ~s(href="#{~p"/#{user}/settings/privacy"}")
      assert html =~ ~s(href="#{~p"/#{user}/settings"}")
    end
  end

  describe "privacy & visibility" do
    # The boxes are framed positively ("Allow …") but the fields are the
    # opt-out noindex?/noai?, so a CHECKED box submits "false" (allow) and an
    # UNCHECKED box submits the hidden "true" (opt out).

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

  describe "notifications" do
    test "saving the notifications toggle persists and stays on the page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/#{user}/settings/notifications", user: %{"notification_emails?" => "false"})

      assert redirected_to(conn) == ~p"/#{user}/settings/notifications"
      assert Repo.get(User, user.id).notification_emails? == false
    end
  end

  describe "account hub" do
    test "surfaces username, emails, data export, the security pages and delete", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/settings") |> html_response(200)

      assert html =~ ~s(href="#{~p"/#{user}/slugs/new"}")
      assert html =~ ~s(href="#{~p"/#{user}/emails"}")
      assert html =~ ~s(href="#{~p"/#{user}/export"}")
      assert html =~ ~s(href="#{~p"/blocks"}")
      assert html =~ ~s(href="#{~p"/connected_apps"}")
      assert html =~ ~s(href="#{~p"/access_tokens"}")
      assert html =~ ~s(href="#{~p"/moderation/cases"}")
      assert html =~ ~s(id="delete-account")
    end
  end
end
