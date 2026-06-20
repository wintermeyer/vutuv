defmodule VutuvWeb.SessionControllerTest do
  use VutuvWeb.ConnCase, async: false
  import Swoosh.TestAssertions

  alias Vutuv.Accounts

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

      # Opens in a new tab so the visitor keeps the PIN form open.
      assert html_response(conn, 200) =~ ~s(href="/sent_emails" target="_blank")
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

  # A visitor who never gets their PIN must be able to ask for a fresh one and,
  # failing that, abandon the pending login entirely (otherwise the landing page
  # stays pinned to the PIN-entry form — see "POST /login/cancel").
  @pending_attrs %{
    "emails" => %{"0" => %{"value" => "pending@example.com"}},
    "first_name" => "Pending"
  }

  describe "POST /login/resend" do
    test "re-sends a fresh PIN and keeps the visitor on the PIN page", %{conn: conn} do
      {:ok, _user} = Accounts.register_user(conn, @pending_attrs)

      # Step 1 mints a PIN, sets the signed identity cookie and renders the PIN
      # form (which now carries the resend form's CSRF token).
      conn = post(conn, ~p"/login", session: %{"email" => "pending@example.com"})
      assert html_response(conn, 200) =~ ~s(name="session[pin]")
      _first = sent_pin()

      # Resend through the CSRF-enforced path, carrying the cookie forward.
      conn = submit_with_csrf(conn, ~p"/login/resend", %{})

      assert html_response(conn, 200) =~ ~s(name="session[pin]")
      # A second PIN email actually went out.
      assert sent_pin()
    end

    test "redirects to /login when no PIN is pending", %{conn: conn} do
      conn = post(conn, ~p"/login/resend", %{})

      assert redirected_to(conn) == ~p"/login"
      assert_no_email_sent()
    end
  end

  describe "POST /login/cancel" do
    test "clears the pending login so the landing page works again", %{conn: conn} do
      {:ok, _user} = Accounts.register_user(conn, @pending_attrs)
      conn = post(conn, ~p"/login", session: %{"email" => "pending@example.com"})
      _ = sent_pin()

      # While a PIN is pending, "/" is hijacked to the PIN form (the bug under
      # test only matters because of this).
      trapped = get(conn, ~p"/")
      assert html_response(trapped, 200) =~ ~s(name="session[pin]")

      # Cancel drops the identity cookie and bounces to the login form.
      cancelled = submit_with_csrf(trapped, ~p"/login/cancel", %{})
      assert redirected_to(cancelled) == ~p"/login"

      # Now "/" shows the sign-up form again, not the PIN page.
      freed = get(cancelled, ~p"/")
      body = html_response(freed, 200)
      refute body =~ ~s(name="session[pin]")
      assert body =~ "new_registration"
    end
  end
end
