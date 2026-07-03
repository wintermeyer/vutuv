defmodule VutuvWeb.SettingsShellTest do
  @moduledoc """
  The shared settings shell across the user-agnostic /settings scope (the
  hub's subpages and every section editor), and the clean split it enables:
  /settings/<section> is the editor (shell, sidebar, back link), while the
  /:slug/<section> twin stays the classic public breadcrumbs page for every
  viewer, with only a quiet "Manage ›" bridge for the owner.
  """
  use VutuvWeb.ConnCase, async: true

  describe "the /settings editors" do
    test "every section editor renders inside the settings shell", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

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
        html = conn |> recycle() |> get(path) |> html_response(200)
        assert html =~ "data-settings-shell", "expected the shell on #{path}"
        # The way back to the hub, and the sidebar to every sibling area.
        assert html =~ ~s(href="#{~p"/settings"}")
        assert html =~ ~s(href="#{~p"/settings/privacy"}")
        # No classic profile breadcrumbs inside the editor.
        refute html =~ ~s(class="breadcrumbs")
      end
    end

    test "the new-entry form's breadcrumbs lead back to settings, not the public users trail",
         %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/work_experiences/new") |> html_response(200)

      assert html =~ ~s(href="#{~p"/settings"}")
      assert html =~ ~s(href="#{~p"/settings/work_experiences"}")
      refute html =~ ">Users<"
    end
  end

  describe "the public /:slug section pages" do
    test "a visitor gets the classic breadcrumbs page with no settings chrome", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      other = insert_activated_user()

      html = conn |> get(~p"/#{other}/work_experiences") |> html_response(200)

      refute html =~ "data-settings-shell"
      assert html =~ ~s(class="breadcrumbs")
      refute html =~ ~s(class="profile-header__manage")
    end

    test "the owner gets the same public page plus the quiet Manage bridge", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      html = conn |> get(~p"/#{user}/links") |> html_response(200)

      refute html =~ "data-settings-shell"
      assert html =~ ~s(class="breadcrumbs")
      assert html =~ ~s(class="profile-header__manage")
      assert html =~ ~s(href="#{~p"/settings/links"}")
    end

    test "a logged-out visitor gets the classic page too", %{conn: conn} do
      other = insert_activated_user()
      html = conn |> get(~p"/#{other}/work_experiences") |> html_response(200)

      refute html =~ "data-settings-shell"
      assert html =~ ~s(class="breadcrumbs")
    end
  end
end
