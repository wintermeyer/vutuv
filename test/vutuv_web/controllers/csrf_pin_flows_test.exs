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
      user = insert(:user, email_confirmed?: true)
      insert(:email, value: "pin-login@example.com", user: user)

      conn = post(build_conn(), ~p"/login", session: %{"email" => "pin-login@example.com"})
      assert html_response(conn, 200) =~ "_csrf_token"
      pin = sent_pin()

      conn = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => pin}})

      # This member follows nobody yet, so home is their own profile rather than
      # an empty feed (the feed-branch landing is covered just below).
      assert redirected_to(conn) == ~p"/#{user}"
      assert get_session(conn, :user_id) == user.id
      # The returning-user greeting is personal; first-time sign-ups get their
      # own. No unread conversations here, so no message count is appended.
      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Welcome back, #{user.first_name}!"
    end

    test "lands a member who follows someone on the feed" do
      user = insert(:user, email_confirmed?: true)
      insert(:email, value: "feeder@example.com", user: user)
      # One follow of an activated account is enough to make the feed their home.
      insert(:follow, follower: user, followee: insert(:activated_user))

      conn = post(build_conn(), ~p"/login", session: %{"email" => "feeder@example.com"})
      pin = sent_pin()
      conn = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => pin}})

      assert redirected_to(conn) == ~p"/feed"
    end

    test "greets a returning member by name and counts their unread conversations" do
      user = insert(:user, email_confirmed?: true)
      insert(:email, value: "greet@example.com", user: user)

      # One conversation holding a message the member has not read — the same
      # count the shell's message badge shows.
      other = insert(:user)
      conversation = insert_conversation_between(other, user)
      {:ok, _} = Vutuv.Chat.send_message(other, conversation.id, "ping")

      conn = post(build_conn(), ~p"/login", session: %{"email" => "greet@example.com"})
      pin = sent_pin()
      conn = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => pin}})

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Welcome back, #{user.first_name}! You have 1 new message."
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
