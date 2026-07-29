defmodule VutuvWeb.UsernameController do
  @moduledoc """
  The username (@handle) page and the two-step rename behind it.

  A rename is a public-identity change: the old profile address stops working
  immediately, the freed handle can be claimed by anyone, and every stored
  mention of it is rewritten. Until issue #1086 a live session was the only
  thing standing between a borrowed laptop and all of that, while the two
  changes either side of it on the settings menu (adding an email, deleting the
  account) both re-confirm with a PIN. So step 1 now only *validates and
  remembers* the new handle, and step 2 asks the member to prove it is them —
  with whichever factor they have:

    * a **passkey** (WebAuthn), the one-tap path for members who enrolled one;
    * a code from their **authenticator app** or their printed **one-time code
      list**, typed into the same field as;
    * a **PIN emailed** to one of their own addresses — the floor everybody
      has. With several addresses on file the member picks which one gets it,
      checked against `Accounts.list_email_values/1` so the field can never be
      turned into a relay to an attacker's inbox.

  A member with a single address and no enrolled factor never sees a choice:
  the PIN is on its way before the confirmation page renders, so their flow is
  the familiar "type the number from your inbox".

  The pending handle lives in the session (signed, so it cannot be edited from
  the browser) rather than in the PIN row, because all three factors converge on
  one commit path and only the PIN has a payload. `Accounts.update_username/2`
  re-runs every validation inside its transaction, so a handle that goes stale
  between the two steps still cannot slip through.
  """

  use VutuvWeb, :controller

  # Changing the username is owner-only.
  plug(VutuvWeb.Plug.AuthUser)
  plug(:scrub_params, "user" when action in [:create])

  alias Vutuv.AccountEvents
  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Credentials
  alias Vutuv.LoginCodes
  alias Vutuv.Mentions
  alias Vutuv.Notifications.Emailer
  alias VutuvWeb.RateLimit

  # The pending rename, and the proof that carried it, both live in the session.
  @pending_key :username_change
  @pending_at_key :username_change_at
  @pin_email_key :username_change_pin_email
  @passkey_key :username_change_passkey_at
  @challenge_key :username_change_challenge

  # How long a completed passkey ceremony stays good for. Long enough to cover a
  # slow authenticator and a re-read of the page, short enough that an abandoned
  # confirmation cannot be finished by whoever sits down next.
  @passkey_max_age_seconds 600

  # How long a started rename waits for its confirmation. Matched to the PIN's
  # own lifetime, so the two halves of the flow go stale together instead of
  # leaving a remembered handle behind for a code that arrives much later.
  @pending_max_age_seconds 1800

  def new(conn, _params) do
    user = conn.assigns[:user]

    # Deliberately does NOT drop a confirmation in progress. A GET must be safe,
    # and this URL is one the member reaches by accident all the time: the
    # sidebar row, the breadcrumb, the browser's Back button, a link prefetch.
    # Clearing here made any of those silently destroy the pending rename, so
    # the next correct PIN answered "this confirmation expired" with nothing on
    # screen to explain why (hit while smoke-testing this flow). The pending
    # handle is not a credential — `create` overwrites it on the next submit and
    # every commit path still demands a fresh factor — so it is safe to keep,
    # bounded by @pending_max_age_seconds.
    render_new(conn, user, User.username_changeset(user))
  end

  # Step 1: validate the handle without writing anything, remember it, and move
  # on to the confirmation. Nothing is renamed here any more.
  def create(conn, %{"user" => params}) do
    user = conn.assigns[:current_user]

    case Accounts.validate_username_change(user, params) do
      {:ok, handle} ->
        conn
        |> put_session(@pending_key, handle)
        |> put_session(@pending_at_key, System.system_time(:second))
        |> delete_session(@passkey_key)
        |> start_confirmation(user, handle)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_new(user, changeset)
    end
  end

  # A member who has no way to confirm other than email, and only one address to
  # mail, is not asked anything: send the PIN straight away so the confirmation
  # page is simply "type the number we just sent you". Everyone else gets the
  # page first and picks their factor - mailing a PIN nobody asked for would
  # train members to ignore exactly the mail that is meant to alarm them.
  defp start_confirmation(conn, user, handle) do
    options = confirmation_options(user)

    if options.email_only? and match?([_], options.emails) do
      conn
      |> mail_pin(user, hd(options.emails), handle)
      |> render_confirm(user, options)
    else
      render_confirm(conn, user, options)
    end
  end

  # Step 2, the page: what will change, and every way this member can confirm
  # it. Reachable on its own so a reload (or the redirect after a PIN send)
  # lands somewhere sensible; with nothing pending it sends them back to start.
  def confirm(conn, _params) do
    user = conn.assigns[:current_user]

    case pending_handle(conn) do
      nil -> redirect(conn, to: ~p"/settings/username")
      _handle -> render_confirm(conn, user, confirmation_options(user))
    end
  end

  # "Email me a PIN": mails it to the address the member picked, which must be
  # one of their own.
  def send_pin(conn, params) do
    user = conn.assigns[:current_user]

    with handle when is_binary(handle) <- pending_handle(conn),
         {:ok, email} <- chosen_email(user, params) do
      case RateLimit.check_username_pin(conn, user) do
        :ok ->
          conn
          |> mail_pin(user, email, handle)
          |> put_flash(:info, gettext("PIN sent to %{email}.", email: email))
          |> redirect(to: ~p"/settings/username/confirm")

        :rate_limited ->
          conn
          |> put_flash(:error, gettext("Too many PIN requests. Please try again later."))
          |> redirect(to: ~p"/settings/username/confirm")
      end
    else
      nil ->
        expired(conn)

      :error ->
        conn
        # Not a scolding: the only way to get here is a stale form or a hand-made
        # request, so say plainly which addresses are on offer.
        |> put_flash(:error, gettext("Please choose one of your own email addresses."))
        |> redirect(to: ~p"/settings/username/confirm")
    end
  end

  # Step 2, the commit. Two ways in, one exit: the code field (emailed PIN,
  # authenticator app, or one-time list code), or the session stamp a completed
  # passkey ceremony left behind.
  def verify(conn, params) do
    user = conn.assigns[:current_user]

    case pending_handle(conn) do
      nil -> expired(conn)
      handle -> confirm_and_rename(conn, user, handle, params)
    end
  end

  defp confirm_and_rename(conn, user, handle, params) do
    cond do
      fresh_passkey_proof?(conn) ->
        rename(conn, user, handle, "passkey")

      is_binary(params["username_confirmation"]["code"]) ->
        verify_code(conn, user, handle, params["username_confirmation"]["code"])

      true ->
        conn
        |> put_flash(:error, gettext("Please confirm the change before we rename your account."))
        |> redirect(to: ~p"/settings/username/confirm")
    end
  end

  defp verify_code(conn, user, handle, code) do
    case RateLimit.check(conn, :username_change_confirm, user.id) do
      :ok -> check_code(conn, user, handle, code)
      :rate_limited -> abort(conn, gettext("Too many attempts. Please try again later."))
    end
  end

  defp check_code(conn, user, handle, code) do
    case Accounts.check_confirmation_code(user, code, "username") do
      {:ok, user, factor} ->
        rename(conn, user, handle, factor)

      # Wrong but still usable: stay on the page so they can try again.
      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: ~p"/settings/username/confirm")

      # Spent, timed out or locked out: the pending change goes with them, so
      # the member restarts from the form rather than from a dead code.
      {:already_used, message} ->
        abort(conn, message, :info)

      {:expired, message} ->
        abort(conn, message)

      :lockout ->
        abort(conn, gettext("Too many incorrect attempts."))
    end
  end

  # The one place a rename is committed, whichever factor proved identity.
  defp rename(conn, user, handle, factor) do
    # The old handle is gone afterwards, so count the posts it appears in now to
    # report how many were updated.
    affected = Mentions.count_post_mentions(user.username)
    old_handle = user.username

    case Accounts.update_username(user, %{"username" => handle}) do
      {:ok, user} ->
        # The durable answer to "my username is different and I did not do that"
        # (issue #1087). Both handles are public identity, so they go in whole;
        # `factor` records which of the three proofs was given.
        AccountEvents.record(user, "username_changed",
          conn: conn,
          factor: factor,
          details: %{from: old_handle, to: user.username}
        )

        conn
        |> clear_pending()
        |> put_flash(:info, rename_success_message(user.username, affected))
        |> redirect(to: ~p"/#{user}")

      # Everything was valid one step ago, so this is the narrow race the second
      # step opens: someone claimed the handle in between, or the quota ran out
      # in another tab. Send them back to the form with the real reason.
      {:error, changeset} ->
        conn
        |> clear_pending()
        |> put_status(:unprocessable_entity)
        |> render_new(user, changeset, affected)
    end
  end

  # ── Passkey confirmation (issue #795's ceremony, reused) ──
  #
  # Two JSON requests driven by assets/js/webauthn.js, exactly like the passkey
  # login: mint a challenge, then verify the assertion. The difference is what
  # success means here - it does NOT rename anything. It stamps the session and
  # the JS submits the ordinary confirmation form, so the rename keeps its one
  # commit path, its CSRF check and its normal flash-and-redirect exit.

  def passkey_challenge(conn, _params) do
    case RateLimit.check(conn, :username_change_confirm, conn.assigns[:current_user].id) do
      :ok ->
        {challenge, options} = Credentials.authentication_options()

        conn
        |> put_session(@challenge_key, challenge)
        |> json(options)

      :rate_limited ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: gettext("Too many attempts. Please try again later.")})
    end
  end

  def passkey_verify(conn, params) do
    user = conn.assigns[:current_user]

    with :ok <- RateLimit.check(conn, :username_change_confirm, user.id),
         %Wax.Challenge{} = challenge <- get_session(conn, @challenge_key),
         handle when is_binary(handle) <- pending_handle(conn),
         {:ok, %User{id: owner_id}} <- Credentials.verify_authentication(challenge, params),
         # The ceremony proves *a* passkey for this site, not whose. Without
         # this check any member's passkey would confirm any other member's
         # rename, which is the whole point of the step.
         true <- owner_id == user.id do
      conn
      |> delete_session(@challenge_key)
      |> put_session(@passkey_key, System.system_time(:second))
      |> json(%{ok: true})
    else
      :rate_limited ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{ok: false, error: gettext("Too many attempts. Please try again later.")})

      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, error: gettext("This confirmation expired. Please start again.")})

      _ ->
        conn
        |> delete_session(@challenge_key)
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, error: gettext("That passkey could not be verified.")})
    end
  end

  # ── The pending change ──

  defp pending_handle(conn) do
    with handle when is_binary(handle) <- get_session(conn, @pending_key),
         true <- fresh?(get_session(conn, @pending_at_key), @pending_max_age_seconds) do
      handle
    else
      _ -> nil
    end
  end

  defp fresh?(at, max_age) when is_integer(at), do: System.system_time(:second) - at <= max_age
  defp fresh?(_at, _max_age), do: false

  # A passkey ceremony is proof for a short while only, and for one rename: the
  # commit clears the stamp along with the rest of the pending change.
  defp fresh_passkey_proof?(conn) do
    fresh?(get_session(conn, @passkey_key), @passkey_max_age_seconds)
  end

  defp clear_pending(conn) do
    conn
    |> delete_session(@pending_key)
    |> delete_session(@pending_at_key)
    |> delete_session(@pin_email_key)
    |> delete_session(@passkey_key)
    |> delete_session(@challenge_key)
  end

  defp expired(conn) do
    conn
    |> clear_pending()
    |> put_flash(:error, gettext("This confirmation expired. Please start again."))
    |> redirect(to: ~p"/settings/username")
  end

  defp abort(conn, message, kind \\ :error) do
    conn
    |> clear_pending()
    |> put_flash(kind, message)
    |> redirect(to: ~p"/settings/username")
  end

  # The submitted address must be one the member owns. Anything else (a stale
  # form, a hand-made request) is refused rather than silently redirected to
  # their primary address, so "we mailed a PIN" always names where it went.
  defp chosen_email(user, params) do
    chosen =
      params["username_pin"]["email"] |> to_string() |> String.trim() |> String.downcase()

    owned = Accounts.list_email_values(user)

    cond do
      chosen in owned -> {:ok, chosen}
      chosen == "" and owned != [] -> {:ok, hd(owned)}
      true -> :error
    end
  end

  defp mail_pin(conn, user, email, handle) do
    user
    |> Accounts.gen_pin_for("username", handle)
    |> Emailer.username_change_email(email, user, handle)
    |> Emailer.deliver()

    put_session(conn, @pin_email_key, email)
  end

  # What this member can confirm with. `email_only?` is what decides whether the
  # PIN goes out unasked - a member with a passkey or an authenticator app has a
  # faster way in and should not be mailed by default.
  defp confirmation_options(user) do
    passkey? = Credentials.count_for_user(user) > 0
    codes? = LoginCodes.totp_enabled?(user) or LoginCodes.unused_list_codes_count(user) > 0

    %{
      emails: Accounts.list_email_values(user),
      passkey?: passkey?,
      totp?: LoginCodes.totp_enabled?(user),
      list_codes?: LoginCodes.unused_list_codes_count(user) > 0,
      codes?: codes?,
      email_only?: not passkey? and not codes?
    }
  end

  defp render_confirm(conn, user, options) do
    render(conn, "confirm.html",
      user: user,
      new_username: pending_handle(conn),
      pin_email: get_session(conn, @pin_email_key),
      options: options,
      page_title: gettext("Change your username?")
    )
  end

  defp rename_success_message(handle, 0),
    do: gettext("Your username is now @%{handle}.", handle: handle)

  defp rename_success_message(handle, affected) do
    gettext("Your username is now @%{handle}.", handle: handle) <>
      " " <>
      ngettext(
        "We updated %{formatted} post that mentioned your old handle and notified its author.",
        "We updated %{formatted} posts that mentioned your old handle and notified their authors.",
        affected,
        formatted: VutuvWeb.UI.compact_count(affected)
      )
  end

  defp render_new(conn, user, changeset),
    do: render_new(conn, user, changeset, Mentions.count_post_mentions(user.username))

  defp render_new(conn, user, changeset, mention_count) do
    render(conn, "new.html",
      changeset: changeset,
      quota: Accounts.username_change_quota(user),
      mention_count: mention_count,
      page_title: gettext("Username")
    )
  end

  # The page moved from /settings/usernames/new to /settings/username when the
  # username became its own row under Profile; old bookmarks land there.
  def legacy_redirect(conn, _params), do: redirect(conn, to: ~p"/settings/username")

  # Backs the live "is this name free?" check in the change form.
  def availability(conn, params) do
    value = params["value"] |> to_string() |> String.trim() |> String.downcase()
    json(conn, availability_payload(value))
  end

  defp availability_payload(value) do
    # `username_changeset/2` now also rejects a handle already used in a post
    # (the anti-hijack rule). Check "already taken" first so a claimed handle
    # reads "taken" rather than "used in a post"; both can be true at once.
    changeset = User.username_changeset(%User{}, %{"username" => value})

    cond do
      Accounts.username_taken?(value) ->
        %{available: false, message: gettext("@%{handle} is already taken.", handle: value)}

      not changeset.valid? ->
        %{
          available: false,
          message: VutuvWeb.ErrorHelpers.translate_error(changeset.errors[:username])
        }

      true ->
        %{available: true, message: gettext("@%{handle} is available.", handle: value)}
    end
  end
end
