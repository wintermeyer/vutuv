defmodule VutuvWeb.Admin.ApiAppLiveTest do
  @moduledoc """
  The admin OAuth-application list (`/admin/api_apps`): admins-only, lists every
  registered app and suspends/reactivates it reload-free over the socket. The
  classic CSRF POST routes stay as the no-JS / scriptable fallback (covered by
  `ApiAppControllerTest`).
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.ApiAuth.App
  alias Vutuv.Repo

  describe "authorization" do
    test "non-admins are locked out", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/api_apps"), 403)
    end
  end

  describe "listing" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "lists registered apps with their owner", %{conn: conn} do
      app = insert(:oauth_app)

      {:ok, lv, html} = live(conn, ~p"/admin/api_apps")

      assert html =~ app.name
      assert has_element?(lv, "#api-app-#{app.id}")
    end

    test "empty state when nothing is registered", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/api_apps")
      assert html =~ "No application has been registered yet."
    end
  end

  describe "suspend / reactivate" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "suspends an active app in place, no reload", %{conn: conn} do
      app = insert(:oauth_app, suspended_at: nil)

      {:ok, lv, _html} = live(conn, ~p"/admin/api_apps")
      assert has_element?(lv, "#suspend-#{app.id}")

      lv |> element("#suspend-#{app.id}") |> render_click()

      assert has_element?(lv, "#unsuspend-#{app.id}")
      refute has_element?(lv, "#suspend-#{app.id}")
      assert Repo.get!(App, app.id).suspended_at
    end

    test "reactivates a suspended app in place, no reload", %{conn: conn} do
      app =
        insert(:oauth_app, suspended_at: DateTime.truncate(DateTime.utc_now(), :second))

      {:ok, lv, _html} = live(conn, ~p"/admin/api_apps")
      assert has_element?(lv, "#unsuspend-#{app.id}")

      lv |> element("#unsuspend-#{app.id}") |> render_click()

      assert has_element?(lv, "#suspend-#{app.id}")
      refute Repo.get!(App, app.id).suspended_at
    end
  end
end
