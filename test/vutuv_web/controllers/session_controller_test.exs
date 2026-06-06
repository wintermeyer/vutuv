defmodule VutuvWeb.SessionControllerTest do
  use VutuvWeb.ConnCase, async: false
  import Swoosh.TestAssertions

  # The login page is a logged-out-only entry point, like registration
  # (UserController :new/:create) and the landing page (PageController :index).
  # A visitor who is already logged in should be bounced to their profile rather
  # than shown the login form. :delete (logout) is intentionally not guarded.

  describe "GET /login" do
    test "shows the login form to a logged-out visitor", %{conn: conn} do
      conn = get(conn, ~p"/login")

      assert html_response(conn, 200) =~ "session[email]"
    end

    test "redirects an already-logged-in user to their profile", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = get(conn, ~p"/login")

      assert redirected_to(conn) == ~p"/#{user}"
    end
  end

  describe "dev email inbox link" do
    # In dev, login PINs land in the Swoosh local mailbox at /sent_emails.
    # The login page links there as a convenience, but only when the
    # :dev_mailbox flag is set (true in config/dev.exs, off everywhere else),
    # so the link never leaks into production where the route does not exist.
    test "is hidden by default", %{conn: conn} do
      conn = get(conn, ~p"/login")

      refute html_response(conn, 200) =~ "/sent_emails"
    end

    test "links to the dev mailbox when enabled", %{conn: conn} do
      Application.put_env(:vutuv, :dev_mailbox, true)
      on_exit(fn -> Application.delete_env(:vutuv, :dev_mailbox) end)

      conn = get(conn, ~p"/login")

      assert html_response(conn, 200) =~ ~s(href="/sent_emails")
    end
  end

  describe "POST /login" do
    test "does not start a login for an already-logged-in user", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = post(conn, ~p"/login", session: %{"email" => "someone-else@example.com"})

      assert redirected_to(conn) == ~p"/#{user}"
      # The guard halts before login_by_email/2, so no PIN email goes out.
      assert_no_email_sent()
    end
  end
end
