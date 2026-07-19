defmodule VutuvWeb.UrlStructureTest do
  @moduledoc """
  Pins the root-level URL scheme: profiles live at /:slug (GitHub-style) with
  all per-user sub-pages under /:slug/..., while the legacy /users/:slug URLs,
  /sessions/new and /search_queries/... 301 to their new homes. The catch-all
  user scope sits last in the router, so every static route must keep winning
  over a slug lookup.
  """
  use VutuvWeb.ConnCase

  describe "profiles at the URL root" do
    test "GET /:slug renders the profile", %{conn: conn} do
      user = insert_activated_user()
      conn = get(conn, "/#{user.username}")
      assert html_response(conn, 200) =~ user.first_name
    end

    test "sub-pages render under /:slug/...", %{conn: conn} do
      user = insert_activated_user()

      assert conn |> get("/#{user.username}/followers") |> html_response(200)
      assert conn |> get("/#{user.username}/following") |> html_response(200)
    end

    test "static routes keep winning over the slug catch-all", %{conn: conn} do
      # "tags" and "login" are valid slug shapes; the routes must win.
      assert conn |> get("/tags") |> html_response(200)
      assert conn |> get("/login") |> html_response(200)
    end

    test "an unknown slug 404s", %{conn: conn} do
      assert conn |> get("/no-such-user") |> html_response(404)
    end

    test "GET /users (no slug) 404s like any unknown path", %{conn: conn} do
      assert conn |> get("/users") |> html_response(404)
    end
  end

  describe "legacy /users/:slug URLs" do
    test "the profile URL 301s to /:slug", %{conn: conn} do
      user = insert_activated_user()
      conn = get(conn, "/users/#{user.username}")
      assert redirected_to(conn, 301) == "/#{user.username}"
    end

    test "sub-page URLs 301 to /:slug/... and keep the query string", %{conn: conn} do
      user = insert_activated_user()
      conn = get(conn, "/users/#{user.username}/links?page=2")
      assert redirected_to(conn, 301) == "/#{user.username}/links?page=2"
    end

    test "the renamed followees page redirects to /:slug/following", %{conn: conn} do
      user = insert_activated_user()
      conn = get(conn, "/users/#{user.username}/followees")
      assert redirected_to(conn, 301) == "/#{user.username}/following"
    end
  end

  describe "login and logout" do
    test "GET /login renders the login form", %{conn: conn} do
      assert html_response(get(conn, "/login"), 200) =~ ~s(action="/login")
    end

    test "GET /sessions/new 301s to /login", %{conn: conn} do
      assert redirected_to(get(conn, "/sessions/new"), 301) == "/login"
    end

    test "DELETE /logout signs the user out", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = delete(conn, "/logout")
      assert redirected_to(conn) == "/#{user.username}"
      refute get_session(conn, :user_id)
    end

    test "login stamps a per-session live_socket_id and logout disconnects it", %{conn: conn} do
      # Without the disconnect broadcast, the embedded shell and any open
      # live page keep the logged-in chrome and the user's PubSub events
      # until the tab happens to reload. The topic is now per session (issue
      # #794), so revoking one device never disconnects the others.
      {conn, _user} = create_and_login_user(conn)
      live_socket_id = get_session(conn, :live_socket_id)
      assert live_socket_id =~ ~r/^users_socket:[0-9a-f-]{36}$/

      VutuvWeb.Endpoint.subscribe(live_socket_id)
      delete(conn, "/logout")

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end

  describe "search" do
    test "GET /search renders the live search form", %{conn: conn} do
      assert html_response(get(conn, "/search"), 200) =~ ~s(id="search-form")
    end

    test "the legacy /search_queries URLs 301 to /search", %{conn: conn} do
      assert redirected_to(get(conn, "/search_queries/new"), 301) == "/search"
      assert redirected_to(get(conn, "/search_queries/elixir"), 301) == "/search?q=elixir"
    end
  end

  describe "robots.txt" do
    test "fences off auth/private areas but leaves profiles and their sub-pages crawlable", %{
      conn: conn
    } do
      body = conn |> get("/robots.txt") |> response(200)

      # Backstage paths stay blocked.
      assert body =~ "Disallow: /login"
      assert body =~ "Disallow: /search"
      assert body =~ "Allow: /"

      # The per-user detail sub-pages are NOT robots-blocked: they carry a
      # page-level X-Robots-Tag: noindex (VutuvWeb.Plug.NoIndex) instead, so a
      # blocked-but-linked URL can never strand itself in the index.
      refute body =~ "Disallow: /*/emails"
      refute body =~ "Disallow: /*/phone_numbers"

      # The legacy /users/ URLs are 301 redirects and must stay crawlable so
      # the redirect consolidates them onto the canonical /:slug profile.
      refute body =~ "Disallow: /users/"
    end
  end
end
