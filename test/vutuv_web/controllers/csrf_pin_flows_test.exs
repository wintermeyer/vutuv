defmodule VutuvWeb.CsrfPinFlowsTest do
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Accounts.{Email, User}

  # Regression guard for issue #759.
  #
  # Every PIN flow is a two-step POST: step 1 mails a PIN and renders a form,
  # step 2 submits the PIN. That form carries a CSRF token anchored in the
  # session cookie, so the session must stay alive between the two steps.
  #
  # `Phoenix.ConnTest` sets `plug_skip_csrf_protection` on every test conn, so a
  # plain `post/3` never exercises this — which is precisely how the login flow
  # shipped a 403 ("You are not allowed to view this page.") to production. Each
  # test below submits step 2 through `submit_with_csrf/3` (see ConnCase), which
  # re-enables CSRF and replays the rendered token, mirroring a real browser.

  describe "login" do
    test "completes the two-step PIN login with CSRF enforced" do
      user = insert(:user, validated?: true)
      insert(:email, value: "pin-login@example.com", user: user)

      conn = post(build_conn(), ~p"/login", session: %{"email" => "pin-login@example.com"})
      assert html_response(conn, 200) =~ "_csrf_token"
      pin = sent_pin()

      conn = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => pin}})

      assert redirected_to(conn) == ~p"/#{user}"
      assert get_session(conn, :user_id) == user.id
    end
  end

  describe "email change" do
    test "completes the two-step email confirmation with CSRF enforced", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = post(conn, ~p"/#{user}/emails", email: %{"value" => "added@example.com"})
      assert html_response(conn, 200) =~ "_csrf_token"
      pin = sent_pin()

      conn =
        submit_with_csrf(
          conn,
          ~p"/#{user}/emails/confirmation",
          %{"email_confirmation" => %{"pin" => pin}}
        )

      assert redirected_to(conn) == ~p"/"
      assert Repo.get_by(Email, value: "added@example.com")
    end
  end

  describe "account deletion" do
    test "completes the two-step account deletion with CSRF enforced", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = delete(conn, ~p"/#{user}")
      assert html_response(conn, 200) =~ "_csrf_token"
      pin = sent_pin()

      conn =
        submit_with_csrf(conn, ~p"/account_deletion", %{"account_deletion" => %{"pin" => pin}})

      assert redirected_to(conn) == ~p"/"
      refute Repo.get(User, user.id)
    end
  end
end
