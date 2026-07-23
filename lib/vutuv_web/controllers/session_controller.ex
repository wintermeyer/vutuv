defmodule VutuvWeb.SessionController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Chat
  alias Vutuv.Credentials
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.Home
  alias VutuvWeb.RateLimit
  alias VutuvWeb.UI
  alias VutuvWeb.UserHelpers

  # The login page is logged-out-only, like registration. An already-logged-in
  # visitor is redirected to their home (the feed or, with no follows yet, their
  # profile). :delete (logout) stays unguarded.
  plug(VutuvWeb.Plug.RequireUserLoggedOut when action in [:new, :create, :resend, :cancel])

  def new(conn, _) do
    # If a login PIN is already in flight (the visitor started a login, or the
    # passkey fallback below routed them here), show the PIN-entry form instead
    # of the email form so they can finish — mirroring how "/" is pinned to the
    # PIN form while a PIN is pending (PageController.display_pin_entry/2). Not
    # gated on a PIN row existing in the DB: that would betray whether the
    # address has an account (issue #759's enumeration oracle).
    case Accounts.read_pin_cookie(conn) do
      email when is_binary(email) ->
        conn
        |> flash_passkey_fallback()
        |> render("pin_user_login.html")

      nil ->
        render(conn, "new.html")
    end
  end

  # The passkey fallback (see passkey_challenge/2) marks the session before it
  # bounces the visitor here, so we greet them with the friendly note explaining
  # why they landed on the PIN form. It is set here, in the same request that
  # renders the form, because Phoenix only carries a flash across requests on a
  # redirect response — and the JSON challenge answer that mailed the PIN is a
  # 200, not a 3xx. The marker is one-shot: read it, drop it.
  defp flash_passkey_fallback(conn) do
    if get_session(conn, :passkey_pin_fallback) do
      conn
      |> delete_session(:passkey_pin_fallback)
      |> put_flash(
        :info,
        gettext(
          "You don't have a passkey yet, so we've emailed you a one-time PIN to sign in instead."
        )
      )
    else
      conn
    end
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
  # any discoverable passkey for this site can be used).
  #
  # Two shapes, decided by whether the visitor typed an email first:
  #
  #   * no email — the passkey-first path: mint a discoverable challenge and let
  #     the browser surface any passkey stored for this site.
  #   * an email whose account HAS a passkey — same discoverable challenge (the
  #     email only decides the branch; we never leak that account's credential
  #     ids into the allow-list).
  #   * an email with NO passkey (or no account at all) — the visitor would only
  #     meet an empty native prompt, so fall back to the email-PIN flow: mail a
  #     PIN and route them to the PIN screen, exactly as if they had clicked
  #     "Log in", with a friendly flash (issue #834).
  #
  # The no-passkey and unknown-address branches are byte-identical, so the
  # fallback stays enumeration-safe; the one thing an email reveals is that its
  # account has a passkey (a challenge, not a redirect), the deliberate cost of
  # letting a passkey member sign in by typing their address.
  def passkey_challenge(conn, params) do
    case RateLimit.check(conn, :login_passkey) do
      :ok ->
        email = params["email"]

        cond do
          not is_binary(email) or String.trim(email) == "" ->
            issue_auth_challenge(conn)

          Credentials.passkey_for_email?(email) ->
            issue_auth_challenge(conn)

          true ->
            pin_fallback(conn, String.trim(email))
        end

      :rate_limited ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: gettext("Too many attempts. Please try again later.")})
    end
  end

  defp issue_auth_challenge(conn) do
    {challenge, options} = Credentials.authentication_options()

    conn
    |> put_session(:webauthn_auth_challenge, challenge)
    |> json(options)
  end

  # No passkey for the typed address: behave like the email-PIN step 1. Throttle
  # on the same per-email budget as the "Log in" button so this cannot be used
  # to out-mail that limit, mail the PIN (only when the account exists — the JSON
  # is identical regardless), mark the session so /login greets the visitor with
  # the friendly note, and tell the JS to navigate there. The note is flashed by
  # `new/2` rather than here because Phoenix carries a flash across requests only
  # on a redirect, and this is a 200 JSON answer.
  defp pin_fallback(conn, email) do
    case RateLimit.check(conn, :login_email, email) do
      :ok ->
        {:ok, conn} = Accounts.login_by_email(conn, email)

        conn
        |> put_session(:passkey_pin_fallback, true)
        |> json(%{redirect: ~p"/login"})

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
        # Same landing as the PIN path: home is the feed once you follow someone,
        # otherwise your profile (see VutuvWeb.Home).
        |> json(%{ok: true, redirect: return_to || Home.path(user)})

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
    conn = Accounts.logout(conn)

    # The route is intentionally unguarded, so an anonymous request can reach
    # here — most realistically a double-submit race (a double-click or a client
    # retry) whose second DELETE lands after the first already revoked the
    # session, leaving current_user nil. Building ~p"/#{nil}" would raise
    # ArgumentError ("cannot convert nil to param") and 500, so send those home.
    case user do
      %User{} = user -> redirect(conn, to: ~p"/#{user}")
      _ -> redirect(conn, to: ~p"/")
    end
  end

  # The typed code is checked as the emailed PIN first and then, for members
  # who set one up (issue #912), as an authenticator-app or one-time-list code
  # — same field, same failure handling (Accounts.check_login_code/2).
  defp verify_login_pin(conn, email, pin, context) do
    case Accounts.check_login_code(email, pin) do
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

      # already used — the classic PIN form was submitted twice (a double-tap or
      # back-navigation): the first submit already logged them in, so this is
      # not a failure. Reassure with an :info flash instead of the old scary
      # "PIN expired" error, and drop the spent cookie (issue #839).
      {:already_used, _message} ->
        conn
        |> Accounts.delete_pin_cookie()
        |> put_flash(
          :info,
          gettext("This PIN was already used. If that was you, you are already signed in.")
        )
        |> redirect(to: ~p"/login")

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

        # Land on the newsfeed, not the member's own profile: signing in, the
        # first thing they want is what is new from the people they follow.
        # A member who follows nobody yet (a fresh sign-up) would meet an empty
        # feed, so Home.path/1 sends them to their profile instead. A page that
        # sent them here to log in (the OAuth consent screen) still wins via
        # return_to.
        path = return_to || post_login_path(context, user)

        Accounts.login(conn, user)
        |> Accounts.delete_pin_cookie()
        |> maybe_welcome_flash(path, context, user)
        |> redirect(to: path)

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

  # Where a successful login lands. Normally home (the feed, or the member's
  # own profile while they follow nobody — VutuvWeb.Home). The one exception is
  # the PIN that confirms a brand-new registration: that member goes to the
  # one-time welcome page first, where they are asked once for their location
  # and job search. Gated on BOTH the form's "registration" context and the
  # never-yet-completed flag, so an ordinary login can never be sent there —
  # and a member who abandons the page is not asked again on their next login.
  defp post_login_path("registration", user) do
    if Accounts.needs_welcome?(user), do: ~p"/system/welcome", else: Home.path(user)
  end

  defp post_login_path(_context, user), do: Home.path(user)

  # The greeting belongs on the page the member ends up *reading*. When the
  # registration PIN routes them through the one-time welcome page, that page
  # greets them in its own hero and its questions deserve an uncluttered
  # screen, so the toast is skipped here — VutuvWeb.WelcomeController raises the
  # same greeting when it hands them on to their profile, where the onboarding
  # checklist it points at actually lives.
  defp maybe_welcome_flash(conn, path, context, user) do
    if path == ~p"/system/welcome" do
      conn
    else
      put_flash(conn, :info, welcome_flash(context, user))
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
  # shows, so the two never disagree). The newcomer wording lives in
  # UserHelpers because the welcome page raises the very same greeting when it
  # is the one that hands the member on to their profile.
  defp welcome_flash("registration", %User{} = user),
    do: UserHelpers.registration_flash(user)

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
        # `count` stays the plural selector, but the rendered number rides a
        # separate `%{formatted}` placeholder so it goes through the count
        # formatter — ngettext auto-binds `%{count}` to the raw integer, which a
        # member with >999 unread conversations would otherwise see run together.
        ngettext(
          "You have %{formatted} new message.",
          "You have %{formatted} new messages.",
          count,
          formatted: UI.delimited_count(count)
        )
    end
  end
end
