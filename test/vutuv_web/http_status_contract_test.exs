defmodule VutuvWeb.HttpStatusContractTest do
  @moduledoc """
  The application-wide HTTP status contract in one place: 200 only when
  the request actually succeeded, and the honest code otherwise —
  redirects for browser flows that need a login, 404 for pages that hide
  their existence, 403 for forbidden, 422 for failed validation, 429 over
  a rate limit. A page quietly answering 200 where it shouldn't is a
  regression this file catches.
  """

  use VutuvWeb.ConnCase

  describe "anonymous visitors" do
    test "public pages answer 200", %{conn: conn} do
      for path <- ["/", "/login", "/community", "/developers", "/llms.txt", "/health", "/ads"] do
        assert get(conn, path).status == 200, "expected 200 for #{path}"
      end
    end

    test "login-required browser pages redirect instead of rendering", %{conn: _conn} do
      # Classic controller pages bounce to the start page with a flash …
      for path <- ["/reports/new", "/ads/bookings", "/moderation/cases", "/admin"] do
        conn = get(build_conn(), path)
        assert conn.status == 302, "expected a redirect for #{path}, got #{conn.status}"
      end

      # … and the login-required LiveViews bounce to /login. /notifications
      # used to leak an empty 200 here.
      for path <- ["/feed", "/messages", "/notifications", "/likes", "/bookmarks"] do
        conn = get(build_conn(), path)
        assert conn.status == 302, "expected a redirect for #{path}, got #{conn.status}"
        assert redirected_to(conn) == "/login"
      end
    end

    test "pages that hide their existence answer 404", %{conn: conn} do
      for path <- ["/access_tokens", "/connected_apps", "/developers/apps", "/blocks"] do
        assert get(build_conn(), path).status == 404, "expected 404 for #{path}"
      end

      assert get(conn, "/no-such-member-xyz").status == 404
    end
  end

  describe "logged-in members" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, conn: conn, user: user}
    end

    test "their pages answer 200", %{conn: conn} do
      for path <- ["/access_tokens", "/connected_apps", "/developers/apps", "/blocks"] do
        assert get(conn, path).status == 200, "expected 200 for #{path}"
      end
    end

    test "the admin panel answers 403 for non-admins", %{conn: conn} do
      assert get(conn, "/admin").status == 403
    end

    test "a failed form validation answers 422, not 200", %{conn: conn, user: user} do
      # Through the shared save/3 chokepoint (an address without a value) …
      conn1 = post(conn, "/#{user.active_slug}/phone_numbers", phone_number: %{"value" => ""})
      assert conn1.status == 422

      # … and through a hand-written error branch (a token without scopes).
      conn2 = post(conn, ~p"/access_tokens", token: %{"name" => "", "scopes" => []})
      assert conn2.status == 422
    end
  end

  describe "rate limits" do
    test "the login email step answers 429 over the limit", %{conn: conn} do
      previous = Application.get_env(:vutuv, :rate_limit)
      Application.put_env(:vutuv, :rate_limit, enabled: true)
      Vutuv.RateLimiter.reset()
      on_exit(fn -> Application.put_env(:vutuv, :rate_limit, previous) end)

      last =
        Enum.reduce(1..10, conn, fn _n, _acc ->
          post(build_conn(), ~p"/login", session: %{"email" => "rate@example.com"})
        end)

      assert last.status == 429
    end
  end
end
