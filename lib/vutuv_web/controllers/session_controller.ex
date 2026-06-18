defmodule VutuvWeb.SessionController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Chat
  alias Vutuv.Credentials
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.RateLimit

  # The login page is logged-out-only, like registration. An already-logged-in
  # visitor is redirected to their profile. :delete (logout) stays unguarded.
  plug(VutuvWeb.Plug.RequireUserLoggedOut when action in [:new, :create, :resend, :cancel])

  def new(conn, _) do
    render(conn, "new.html")
  end

  # Step 1: the visitor types their email. We mail a PIN, stash the identity in
  # the signed cookie and render the PIN-entry form in the same tab.
  def create(conn, %{"session" => %{"email" => email}}) do
    case RateLimit.check(conn, :login_email, email) do
      :ok ->
        # Always advances to the PIN screen — login_by_email/2 mails a PIN
        # only when the address has an account, but the response is the same
        # either way so it cannot be used to find out who has an account.
        {:ok, conn} = Accounts.login_by_email(conn, email)
        render(conn, "pin_user_login.html")

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> put_status(:too_many_requests)
        |> render("new.html")
    end
  end

  # Step 2: the visitor types the PIN. Identity comes from the signed cookie.
  # The post-registration confirmation form marks itself with a context so the
  # greeting fits a first-time member (cosmetic only, so client-set is fine).
  def create(conn, %{"session" => %{"pin" => pin} = session}) do
    with :ok <- RateLimit.check(conn, :login_pin),
         email when is_binary(email) <- Accounts.read_pin_cookie(conn) do
      verify_login_pin(conn, email, pin, session["context"])
    else
      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: ~p"/login")

      nil ->
        conn
        |> put_flash(:error, gettext("Your login session expired. Please try again."))
        |> redirect(to: ~p"/login")
    end
  end

  # "Resend PIN": mint and mail a fresh PIN for the pending identity (carried by
  # the signed cookie), then stay on the PIN-entry form. Throttled on its own
  # slow budget so it cannot reset the attempt counter into a brute-force loop.
  def resend(conn, _params) do
    case Accounts.read_pin_cookie(conn) do
      email when is_binary(email) ->
        case RateLimit.check_login_resend(conn, email) do
          :ok ->
            resend_pin(conn, email)

          :rate_limited ->
            conn
            |> put_flash(:error, gettext("Too many PIN requests. Please try again later."))
            |> put_status(:too_many_requests)
            |> render("pin_user_login.html")
        end

      nil ->
        conn
        |> put_flash(:error, gettext("Your login session expired. Please try again."))
        |> redirect(to: ~p"/login")
    end
  end

  # "Use a different email address": abandon the pending login by dropping the
  # identity cookie. This frees the landing page, which is otherwise pinned to
  # the PIN-entry form while a PIN is in flight, so the visitor can sign in or
  # register as someone else.
  def cancel(conn, _params) do
    conn
    |> Accounts.delete_pin_cookie()
    |> put_flash(:info, gettext("Okay, let's start over."))
    |> redirect(to: ~p"/login")
  end

  # ── Passkey login (issue #795) ──
  # Two requests driven by assets/js/webauthn.js: step 1 mints a WebAuthn
  # challenge and stashes it in the session; step 2 verifies the authenticator's
  # assertion against it and funnels into the SAME Accounts.login/2 exit the PIN
  # flow uses. Both answer JSON; the JS fetch must not send `Accept:
  # application/json` (the :browser pipeline's `accepts ["html"]` would 406 it),
  # exactly like the username-availability endpoint.

  # Step 1: hand the browser a fresh authentication challenge (no allow-list, so
  # any discoverable passkey for this site can be used — no email typed first).
  def passkey_challenge(conn, _params) do
    case RateLimit.check(conn, :login_passkey) do
      :ok ->
        {challenge, options} = Credentials.authentication_options()

        conn
        |> put_session(:webauthn_auth_challenge, challenge)
        |> json(options)

      :rate_limited ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: gettext("Too many attempts. Please try again later.")})
    end
  end

  # Step 2: verify the assertion against the stored challenge and log the member
  # in (subject to the same moderation gate the PIN flow applies). Returns a
  # redirect target the JS navigates to so the flash and chrome render fresh.
  def passkey_verify(conn, params) do
    with :ok <- RateLimit.check(conn, :login_passkey),
         %Wax.Challenge{} = challenge <- get_session(conn, :webauthn_auth_challenge),
         {:ok, user} <- Credentials.verify_authentication(challenge, params) do
      complete_passkey_login(conn, user)
    else
      :rate_limited ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{ok: false, error: gettext("Too many attempts. Please try again later.")})

      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, error: gettext("Your sign-in attempt expired. Please try again.")})

      {:error, _reason} ->
        conn
        |> clear_auth_challenge()
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, error: gettext("That passkey could not be verified.")})
    end
  end

  # The correct-assertion path: the SAME moderation gate and Accounts.login/2
  # exit as handle_login/3, but answering JSON for the fetch ceremony.
  defp complete_passkey_login(conn, user) do
    case Vutuv.Moderation.login_block(user) do
      nil ->
        {return_to, conn} = pop_login_return_to(conn)

        conn
        |> clear_auth_challenge()
        |> Accounts.login(user)
        |> put_flash(:info, welcome_flash(nil, user))
        |> json(%{ok: true, redirect: return_to || ~p"/#{user}"})

      {:suspended, until} ->
        conn
        |> clear_auth_challenge()
        |> put_status(:forbidden)
        |> json(%{
          ok: false,
          error:
            gettext("This account is suspended until %{date}.",
              date: Calendar.strftime(until, "%Y-%m-%d")
            )
        })

      :deactivated ->
        conn
        |> clear_auth_challenge()
        |> put_status(:forbidden)
        |> json(%{ok: false, error: gettext("This account has been deactivated.")})
    end
  end

  defp clear_auth_challenge(conn), do: delete_session(conn, :webauthn_auth_challenge)

  defp resend_pin(conn, email) do
    {:ok, conn} = Accounts.login_by_email(conn, email)

    conn
    |> put_flash(:info, gettext("A new PIN is on its way to your email."))
    |> render("pin_user_login.html")
  end

  def delete(conn, _) do
    user = conn.assigns[:current_user]

    conn
    |> Accounts.logout()
    |> redirect(to: ~p"/#{user}")
  end

  defp verify_login_pin(conn, email, pin, context) do
    case Accounts.check_pin(email, pin, "login") do
      # correct, drop cookie, log the user in (unless moderation blocks it)
      {:ok, user} ->
        handle_login(conn, user, context)

      # incorrect, let them retry — but count the failure against a
      # server-side per-identity budget so an address WITHOUT an account
      # locks out after the same number of wrong PINs as a real one. Without
      # this, only real accounts (which have a LoginPin row to count against)
      # ever reach the lockout, revealing which addresses are registered.
      {:error, reason} ->
        case Accounts.record_login_pin_failure(email) do
          :locked ->
            lockout(conn)

          :ok ->
            conn
            |> put_flash(:error, reason)
            |> redirect(to: ~p"/")
        end

      # expired, drop cookie
      {:expired, message} ->
        conn
        |> Accounts.delete_pin_cookie()
        |> put_flash(:error, message)
        |> redirect(to: ~p"/login")

      # locked out (a real account's per-PIN counter tripped), drop cookie
      :lockout ->
        lockout(conn)
    end
  end

  # The correct-PIN path: log the user in unless moderation blocks the account.
  defp handle_login(conn, user, context) do
    case Vutuv.Moderation.login_block(user) do
      nil ->
        # A page that sent the visitor to log in (the OAuth consent screen)
        # gets them back; renew-style session handling keeps the marker alive
        # through the PIN round trip.
        {return_to, conn} = pop_login_return_to(conn)

        Accounts.login(conn, user)
        |> Accounts.delete_pin_cookie()
        |> put_flash(:info, welcome_flash(context, user))
        |> redirect(to: return_to || ~p"/#{user}")

      {:suspended, until} ->
        conn
        |> Accounts.delete_pin_cookie()
        |> put_flash(
          :error,
          gettext("This account is suspended until %{date}.",
            date: Calendar.strftime(until, "%Y-%m-%d")
          )
        )
        |> redirect(to: ~p"/")

      :deactivated ->
        conn
        |> Accounts.delete_pin_cookie()
        |> put_flash(:error, gettext("This account has been deactivated."))
        |> redirect(to: ~p"/")
    end
  end

  # The one lockout response, shared by the per-PIN DB counter (real account)
  # and the per-identity counter (any address) so the two are byte-identical
  # — the account-enumeration tell would otherwise reappear here.
  defp lockout(conn) do
    conn
    |> Accounts.delete_pin_cookie()
    |> put_flash(:error, gettext("Too many incorrect attempts."))
    |> redirect(to: ~p"/login")
  end

  # Only local paths ("/...", but not protocol-relative "//...") are ever
  # followed — the session value is ours, but defense in depth is cheap.
  defp pop_login_return_to(conn) do
    path = get_session(conn, :login_return_to)
    {ControllerHelpers.safe_return_to(path), delete_session(conn, :login_return_to)}
  end

  # First-time sign-ups get their own greeting; returning members get a
  # personal one with their name and, when they have any, a nudge about the
  # conversations waiting for them (the same count the shell's message badge
  # shows, so the two never disagree).
  defp welcome_flash("registration", %User{first_name: name})
       when is_binary(name) and name != "" do
    gettext("Welcome to vutuv, %{name}!", name: name)
  end

  defp welcome_flash("registration", _user), do: gettext("Welcome to vutuv!")

  defp welcome_flash(_context, %User{} = user) do
    [greeting(user), unread_note(user)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp greeting(%User{first_name: name}) when is_binary(name) and name != "" do
    gettext("Welcome back, %{name}!", name: name)
  end

  defp greeting(_user), do: gettext("Welcome back!")

  defp unread_note(%User{} = user) do
    case Chat.unread_conversations_count(user) do
      0 ->
        nil

      count ->
        ngettext(
          "You have %{count} new message.",
          "You have %{count} new messages.",
          count
        )
    end
  end
end
