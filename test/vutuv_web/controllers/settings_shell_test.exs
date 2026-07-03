defmodule VutuvWeb.SettingsShellTest do
  @moduledoc """
  The shared settings shell on the profile-content section pages (issue: the
  old two-worlds split between /:slug/edit and the profile's "Manage" pages).

  The owner sees every section management page inside the settings shell: a
  "back to Settings" link, the page title, a "View profile" link, and (on md+)
  the sidebar listing every settings area. A visitor (or the owner previewing
  as public) keeps the classic breadcrumbs view, so the public rendering and
  its agent-format docs stay untouched.
  """
  use VutuvWeb.ConnCase, async: true

  describe "section pages for the owner" do
    test "the section index renders inside the settings shell", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/work_experiences") |> html_response(200)

      assert html =~ "data-settings-shell"
      # The way back to the hub and the sidebar to every sibling area.
      assert html =~ ~s(href="#{~p"/#{user}/settings"}")
      assert html =~ ~s(href="#{~p"/#{user}/links"}")
      assert html =~ ~s(href="#{~p"/#{user}/settings/privacy"}")
      # No classic profile breadcrumbs in the shell.
      refute html =~ ~s(class="breadcrumbs")
    end

    test "every section index carries the shell", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      for path <- [
            ~p"/#{user}/work_experiences",
            ~p"/#{user}/educations",
            ~p"/#{user}/links",
            ~p"/#{user}/social_media_accounts",
            ~p"/#{user}/emails",
            ~p"/#{user}/phone_numbers",
            ~p"/#{user}/addresses",
            ~p"/#{user}/tags"
          ] do
        assert conn |> recycle() |> get(path) |> html_response(200) =~ "data-settings-shell"
      end
    end

    test "the new-entry form's breadcrumbs lead back to settings, not the public users trail",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      html = conn |> get(~p"/#{user}/work_experiences/new") |> html_response(200)

      assert html =~ ~s(href="#{~p"/#{user}/settings"}")
      refute html =~ ">Users<"
    end
  end

  describe "section pages for everyone else" do
    test "a visitor keeps the classic breadcrumbs view", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      other = insert_activated_user()

      html = conn |> get(~p"/#{other}/work_experiences") |> html_response(200)

      refute html =~ "data-settings-shell"
      assert html =~ ~s(class="breadcrumbs")
      refute html =~ ~s(href="#{~p"/#{other}/settings"}")
    end

    test "the owner previewing as public sees the visitor view", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      html =
        conn
        |> get(~p"/#{user}/work_experiences?view_as=public")
        |> html_response(200)

      refute html =~ "data-settings-shell"
      assert html =~ ~s(class="breadcrumbs")
    end

    test "a logged-out visitor keeps the classic view too", %{conn: conn} do
      other = insert_activated_user()
      html = conn |> get(~p"/#{other}/work_experiences") |> html_response(200)

      refute html =~ "data-settings-shell"
      assert html =~ ~s(class="breadcrumbs")
    end
  end
end
