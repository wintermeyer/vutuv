defmodule VutuvWeb.SessionControllerTest do
  use VutuvWeb.ConnCase, async: false
  import Swoosh.TestAssertions

  # The login page is a logged-out-only entry point, like registration
  # (UserController :new/:create) and the landing page (PageController :index).
  # A visitor who is already logged in should be bounced to their profile rather
  # than shown the login form. :delete (logout) is intentionally not guarded.

  describe "GET /sessions/new" do
    test "shows the login form to a logged-out visitor", %{conn: conn} do
      conn = get(conn, ~p"/sessions/new")

      assert html_response(conn, 200) =~ "session[email]"
    end

    test "redirects an already-logged-in user to their profile", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = get(conn, ~p"/sessions/new")

      assert redirected_to(conn) == ~p"/users/#{user}"
    end
  end

  describe "POST /sessions" do
    test "does not start a login for an already-logged-in user", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = post(conn, ~p"/sessions", session: %{"email" => "someone-else@example.com"})

      assert redirected_to(conn) == ~p"/users/#{user}"
      # The guard halts before login_by_email/2, so no PIN email goes out.
      assert_no_email_sent()
    end
  end
end
