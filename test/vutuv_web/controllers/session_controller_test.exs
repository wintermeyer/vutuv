defmodule VutuvWeb.SessionControllerTest do
  use VutuvWeb.ConnCase, async: false
  import Swoosh.TestAssertions

  alias Vutuv.Accounts
  alias Vutuv.Chat
  alias Vutuv.Chat.Conversation
  alias Vutuv.Chat.Message
  alias Vutuv.Chat.Participant
  alias Vutuv.UUIDv7

  # The login page is a logged-out-only entry point, like registration
  # (UserController :new/:create) and the landing page (PageController :index).
  # A visitor who is already logged in should be bounced to their home (the feed
  # once they follow someone, else their own profile) rather than shown the
  # login form. :delete (logout) is intentionally not guarded.

  describe "GET /login" do
    test "shows the login form to a logged-out visitor", %{conn: conn} do
      conn = get(conn, ~p"/login")

      assert html_response(conn, 200) =~ "session[email]"
    end

    test "redirects an already-logged-in user to their home", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = get(conn, ~p"/login")

      # A fresh member follows nobody yet, so home is their profile.
      assert redirected_to(conn) == ~p"/#{user}"
    end

    test "shows the PIN form when a login PIN is already in flight", %{conn: conn} do
      # A visitor who has a pending PIN (started a login elsewhere, or was routed
      # here by the passkey fallback) should be able to finish on /login itself,
      # the same way "/" is pinned to the PIN form while a PIN is pending.
      {:ok, conn} = Accounts.login_by_email(conn, "someone@example.com")

      conn = get(recycle(conn), ~p"/login")

      assert html_response(conn, 200) =~ ~s(name="session[pin]")
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

  describe "DELETE /logout" do
    test "signs a logged-in member out and redirects to their profile", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = delete(conn, ~p"/logout")

      assert redirected_to(conn) == ~p"/#{user}"
      refute get_session(conn, :user_id)
    end

    # The route is intentionally unguarded, so an anonymous request can reach the
    # action: a double-submit race (a double-click or a client retry) fires a
    # second DELETE /logout after the first already revoked the session, so it
    # arrives with no current_user. The action must not build ~p"/#{nil}" (which
    # raises ArgumentError -> 500); it bounces such requests to the start page.
    test "redirects an anonymous logout to the start page instead of crashing", %{conn: conn} do
      conn = delete(conn, ~p"/logout")

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_id)
    end
  end

  describe "welcome flash" do
    # A member with >999 unread conversations must not see a run-together
    # integer in the sign-in greeting: the count goes through the formatter, so
    # it is thousands-grouped (issue: unread_note/1 rendered the raw integer).
    test "formats a large unread count as a grouped number, not a run-together integer", %{
      conn: conn
    } do
      attrs = %{
        "emails" => %{"0" => %{"value" => "busy@example.com"}},
        "first_name" => "Busy",
        "tag_list" => "Elixir Cooking Origami"
      }

      {:ok, me} = Accounts.register_user(conn, attrs)

      seed_unread_conversations(me, 1234)
      assert Chat.unread_conversations_count(me) == 1234

      conn = login_via_pin(conn, "busy@example.com")

      flash = Phoenix.Flash.get(conn.assigns.flash, :info)
      # ConnTest defaults to the English locale, so delimited_count/1 groups on
      # commas.
      assert flash =~ "1,234"
      # Never the un-grouped integer.
      refute flash =~ "1234"
    end
  end

  # Seeds `n` accepted conversations in which `me` is an unread participant, so
  # `Chat.unread_conversations_count/1` returns `n`. Reaching a four-digit count
  # without minting a thousand counterparties: the count keys off the
  # participant + unread-message rows, not the conversation's stored pair
  # columns, so those pair columns are drawn from a small pool of filler users
  # (each pair distinct, sorted, to satisfy the unique/sorted-pair constraints).
  defp seed_unread_conversations(me, n) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
    usec = NaiveDateTime.utc_now()

    # A pool of m users yields m*(m-1)/2 distinct pairs; 51 covers > 1200.
    pool = insert_list(51, :activated_user)
    sender = hd(pool)
    ids = Enum.map(pool, & &1.id)

    all_pairs =
      for {a, i} <- Enum.with_index(ids), b <- Enum.drop(ids, i + 1) do
        UUIDv7.sorted_pair(a, b)
      end

    pairs = Enum.take(all_pairs, n)

    conversations =
      Enum.map(pairs, fn {lo, hi} ->
        %{
          id: UUIDv7.generate(),
          user_a_id: lo,
          user_b_id: hi,
          initiator_id: sender.id,
          status: "accepted",
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Conversation, conversations)

    participants =
      Enum.map(conversations, fn c ->
        %{
          id: UUIDv7.generate(),
          conversation_id: c.id,
          user_id: me.id,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Participant, participants)

    messages =
      Enum.map(conversations, fn c ->
        %{
          id: UUIDv7.generate(),
          conversation_id: c.id,
          sender_id: sender.id,
          body: "hi",
          inserted_at: usec,
          updated_at: usec
        }
      end)

    Repo.insert_all(Message, messages)
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
    "first_name" => "Pending",
    "tag_list" => "Elixir Cooking Origami"
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

  # Issue #834: when the visitor typed an email and clicked "Sign in with a
  # passkey" but the account has no passkey, the challenge endpoint must not
  # strand them at the native prompt. It falls back to the email-PIN flow —
  # mails a one-time PIN and tells the JS to move to the PIN screen — exactly
  # as if they had clicked "Log in", but with a friendly flash. The no-passkey
  # and unknown-address responses are byte-identical, so the fallback never
  # betrays who is registered; the only thing typing an email reveals is that
  # the account has a passkey (it gets a challenge instead), a deliberate
  # trade-off for a login the member can actually complete.
  describe "POST /login/passkey/challenge (email-aware, issue #834)" do
    test "an email without a passkey mails a PIN and routes to the PIN screen", %{conn: conn} do
      {:ok, _user} = Accounts.register_user(conn, @pending_attrs)

      conn = post(conn, ~p"/login/passkey/challenge", %{"email" => "pending@example.com"})

      assert %{"redirect" => "/login"} = json_response(conn, 200)
      # No WebAuthn challenge was minted — this is the PIN path, not a ceremony.
      refute get_session(conn, :webauthn_auth_challenge)
      # A real login PIN went out, and no one was logged in by the challenge.
      assert sent_pin()
      refute get_session(conn, :user_id)

      # Following the redirect lands on the PIN-entry form with the friendly note.
      followed = get(recycle(conn), ~p"/login")
      assert html_response(followed, 200) =~ ~s(name="session[pin]")
      assert Phoenix.Flash.get(followed.assigns.flash, :info) =~ "PIN"
    end

    test "an email with a passkey gets a challenge and no PIN", %{conn: conn} do
      {:ok, user} = Accounts.register_user(conn, @pending_attrs)
      insert(:user_credential, user: user)

      conn = post(conn, ~p"/login/passkey/challenge", %{"email" => "pending@example.com"})

      body = json_response(conn, 200)
      assert {:ok, _} = Base.url_decode64(body["challenge"], padding: false)
      assert %Wax.Challenge{} = get_session(conn, :webauthn_auth_challenge)
      refute body["redirect"]
      # A member with a passkey is never mailed a PIN behind their back.
      assert_no_email_sent()
    end

    test "an unknown address routes to the PIN screen without sending mail", %{conn: conn} do
      conn = post(conn, ~p"/login/passkey/challenge", %{"email" => "nobody@example.com"})

      # Same response as a real account with no passkey, and no mail leaks out —
      # so the endpoint stays enumeration-safe.
      assert %{"redirect" => "/login"} = json_response(conn, 200)
      assert_no_email_sent()
    end

    test "a blank email still yields a discoverable challenge", %{conn: conn} do
      conn = post(conn, ~p"/login/passkey/challenge", %{"email" => "   "})

      assert json_response(conn, 200)["challenge"]
      assert %Wax.Challenge{} = get_session(conn, :webauthn_auth_challenge)
    end
  end
end
