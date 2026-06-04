defmodule VutuvWeb.DesignConsistencyTest do
  @moduledoc """
  Guards the "Direction A" design language across the pages that historically
  escaped it: pages must render the standard chrome (`.profile-header` title,
  `.breadcrumbs`, `.card` surface) instead of bare pure.css markup, error pages
  must be styled and helpful, and the German locale must reach LiveView pages
  (the chrome used to flip back to English on /messages and /notifications).
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "page chrome consistency" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "groups index uses the standard page chrome", %{conn: conn, user: user} do
      insert(:group, user: user)
      conn = get(conn, ~p"/users/#{user}/groups")
      html = html_response(conn, 200)

      assert html =~ "profile-header"
      assert html =~ "breadcrumbs"
      assert html =~ ~s(class="card)
      refute html =~ "pure-button"
    end

    test "search terms index uses the standard page chrome", %{conn: conn, user: user} do
      conn = get(conn, ~p"/users/#{user}/search_terms")
      html = html_response(conn, 200)

      assert html =~ "profile-header"
      assert html =~ "breadcrumbs"
      assert html =~ ~s(class="card)
      refute html =~ "pure-button"
    end

    test "the email visibility select is translated", %{conn: conn, user: user} do
      conn =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de")
        |> get(~p"/users/#{user}/edit")

      html = html_response(conn, 200)
      assert html =~ "Öffentlich"
      refute html =~ ~s(>Public<)
    end
  end

  describe "admin dashboard" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      insert(:user, last_name: nil)
      %{conn: conn, admin: admin}
    end

    test "uses the standard chrome and a non-destructive verify button", %{conn: conn} do
      conn = get(conn, ~p"/admin")
      html = html_response(conn, 200)

      assert html =~ "profile-header"
      assert html =~ ~s(class="card)
      # Verifying a user is a positive action, not a destructive one.
      refute html =~ "button--danger"
    end
  end

  describe "error pages" do
    test "the 404 page is styled and links back home", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # The slugs feature is intentionally disabled via Plug.All404.
      conn = get(conn, ~p"/users/#{user}/slugs")
      html = html_response(conn, 404)

      assert html =~ "error-page"
      assert html =~ ~s(href="/")
    end
  end

  describe "locale on LiveView pages" do
    test "a German visitor keeps the German chrome on /notifications", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, view, _html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de")
        |> live(~p"/notifications")

      assert render(view) =~ "Benachrichtigungen"
    end
  end
end
