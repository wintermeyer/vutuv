defmodule Vutuv.Accounts do
  @moduledoc """
  The Accounts context. Handles user registration, authentication,
  email management, and slugs.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query, only: [account_confirmed_row: 1]
  import Vutuv.SearchText, only: [escape_like: 1, name_ilike: 3, normalize_search: 1]
  require Logger

  alias Plug.Conn
  alias Vutuv.Accounts.Email
  alias Vutuv.Accounts.LoginPin
  alias Vutuv.Accounts.MemberCounter
  alias Vutuv.Accounts.ReservedSlugs
  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.Accounts.User
  alias Vutuv.Accounts.UsernameChange
  alias Vutuv.Deliverability
  alias Vutuv.LoginCodes
  alias Vutuv.Moderation
  alias Vutuv.Notifications.Bounces
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Pages
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.Uploads.Crop

  # ── Registration ──

  def register_user(conn, user_params, assocs \\ []) do
    user_params
    |> registration_username()
    |> user_changeset(conn, user_params, assocs)
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        # The sign-up form's "Your tags" field (the virtual `tag_list`): turn
        # it into real user tags now that the user row exists. The field is
        # split on both commas and spaces (`parse_tag_names/1`), so a member who
        # types "JavaScript Go Hunde" gets three separate tags rather than one
        # merged one; case-insensitive de-duplication then drops a repeated tag
        # ("Go, go") before it can trip the unique constraint, so no per-tag
        # insert error is silently swallowed here. The insert above only
        # succeeds when this same parse+dedup yields at least three tags
        # (User.registration_changeset/2's minimum), so a fresh account always
        # lands with tags attached.
        user_params["tag_list"]
        |> Vutuv.Tags.parse_tag_names()
        |> Enum.uniq_by(&String.downcase/1)
        |> Enum.each(&Vutuv.Tags.add_user_tag(user, &1))

        user = Repo.preload(user, user_tags: [:tag])
        maybe_fetch_gravatar(user)
        # The landing-page counter is bumped on confirmation, not here (issue
        # #781) — see activate_user/1. A sign-up that never confirms is swept by
        # delete_unconfirmed_registrations/1 and must not inflate the total.
        {:ok, user}

      error ->
        error
    end
  end

  @doc """
  Whether a failed `register_user/3` changeset failed *only* because the email
  address is already registered (the emails unique constraint fired). The
  sign-up controller masks exactly this case so the form can't leak whether an
  address has an account; classifying it here keeps that security-relevant rule
  next to the constraint that defines it rather than in the web layer.

  `unique_constraint` only fires after the INSERT, which Ecto attempts only on
  an otherwise-valid changeset, so a genuine input error (bad format, missing
  name) never coincides with it.
  """
  def email_already_taken?(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.get_change(:emails, [])
    |> Enum.any?(fn email_changeset ->
      Enum.any?(email_changeset.errors, fn
        {:value, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
        _ -> false
      end)
    end)
  end

  # The initial handle, generated from the name (underscore style, unique,
  # never reserved). nil when no name was given - user_changeset/4 turns that
  # into a changeset error so registration fails cleanly.
  defp registration_username(user_params) do
    if user_params["first_name"] != nil or user_params["last_name"] != nil do
      struct = %User{first_name: user_params["first_name"], last_name: user_params["last_name"]}

      Vutuv.SlugHelpers.gen_handle_unique(struct, User, :username, ReservedSlugs.list())
    end
  end

  defp user_changeset(slug_value, conn, user_params, assocs) do
    search_terms = SearchTerm.create_search_terms(user_params)

    changeset =
      User.registration_changeset(%User{}, user_params)
      |> Ecto.Changeset.put_assoc(:search_terms, search_terms)
      |> put_registration_username(slug_value)
      |> Ecto.Changeset.put_change(:locale, conn.assigns[:locale])

    Enum.reduce([changeset | assocs], fn {type, params}, changeset ->
      Ecto.Changeset.put_assoc(changeset, type, [params])
    end)
  end

  defp put_registration_username(changeset, nil),
    do: Ecto.Changeset.add_error(changeset, :username, "can't be generated without a name")

  defp put_registration_username(changeset, slug_value) do
    changeset
    |> Ecto.Changeset.put_change(:username, slug_value)
    # The generator already dodged collisions; this catches the race where two
    # registrations generate the same handle at once.
    |> Ecto.Changeset.unique_constraint(:username)
  end

  # Best-effort gravatar import: spawned (when enabled) under the app-wide
  # Task.Supervisor rather than an orphaned `Task.start/3`, and disabled in
  # tests via `:fetch_gravatar` so the SQL Sandbox connection is never used by
  # a process that does not own it and no live HTTP request is made.
  defp maybe_fetch_gravatar(user) do
    if Application.get_env(:vutuv, :fetch_gravatar, true) do
      Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn -> store_gravatar(user) end)
    end

    :ok
  end

  defp store_gravatar(user) do
    url = "https://www.gravatar.com/avatar/#{hd(user.emails).md5sum}?s=130&d=404"

    case Req.get(url, receive_timeout: 1000, connect_options: [timeout: 1000]) do
      {:ok, %Req.Response{status: 404}} ->
        nil

      {:ok, %Req.Response{status: 200, body: body, headers: headers}} ->
        content_type = find_content_type(headers)
        filename = "/#{user.username}.#{gravatar_extension(content_type)}"
        path = System.tmp_dir()

        upload = %Plug.Upload{
          content_type: content_type,
          filename: filename,
          path: path <> filename
        }

        File.write(path <> filename, body)

        # Through update_user/2 so the avatar file is written only after the row
        # commits (issue #776), the same as the edit-profile path.
        update_user(user, %{avatar: upload})

      _ ->
        nil
    end
  rescue
    error ->
      Logger.warning("gravatar import failed for user ##{user.id}: #{inspect(error)}")
      nil
  end

  defp find_content_type(headers) do
    case Map.get(headers, "content-type") do
      [value | _] -> value
      _ -> "image/jpeg"
    end
  end

  # A whitelisted file extension from the response content type — dropping any
  # `; charset=...` parameter so the filename isn't e.g. `png; charset=binary`
  # (which fails the avatar extension whitelist and silently drops the import).
  defp gravatar_extension(content_type) do
    case content_type |> String.split(";", parts: 2) |> hd() |> String.trim() do
      "image/png" -> "png"
      _ -> "jpg"
    end
  end

  # ── Authentication ──

  def login(conn, user) do
    user = activate_user(user)

    # Mint a server-side session row so this device can be listed and revoked
    # remotely (issue #794) and a noteworthy login can be emailed about (issue
    # #786). The raw token rides in the cookie; only its hash is stored.
    {token, session} = Vutuv.Sessions.start_session(user, conn)

    conn
    |> Conn.assign(:current_user, user)
    |> Conn.put_session(:user_id, user.id)
    |> Conn.put_session(:session_token, token)
    # Each session gets its OWN live-socket topic (not the shared per-user one),
    # so revoking a single device disconnects only its sockets. The LiveView
    # socket subscribes to this topic on connect; logout, remote revocation and
    # the stale-session sweep broadcast "disconnect" on it so live views never
    # outlive the session that mounted them.
    |> Conn.put_session(:live_socket_id, Vutuv.Sessions.socket_id(session))
    |> Conn.configure_session(renew: true)
  end

  @doc """
  Step 1 of the PIN login: stash the pending identity in the signed cookie
  and advance to the PIN-entry screen. Always returns `{:ok, conn}` — the
  response must **not** reveal whether an account exists for `email`, or it
  becomes an enumeration oracle. A PIN is mailed only when the address
  belongs to an account; an attacker who guesses an unknown address gets
  the identical PIN screen but never receives a PIN.
  """
  def login_by_email(conn, email) do
    advance_to_pin_screen(conn, email, &send_login_pin/2)
  end

  @doc """
  Step 1 of registration when the address is **already taken**. The sign-up
  form must not betray that an account exists, so this returns the exact same
  `{:ok, conn}` — same pin cookie, same PIN-entry screen — as a fresh sign-up:
  the response is byte-identical, which closes the enumeration oracle the
  inline "has already been taken" error used to be. The truth reaches only the
  address owner's inbox, where `Emailer.registration_attempt_email/2` tells
  them someone tried to register and links them to the login page. No PIN is
  sent, so the notice carries nothing a non-owner could act on.
  """
  def notify_registration_attempt(conn, email) do
    advance_to_pin_screen(conn, email, &send_registration_attempt_notice/2)
  end

  # The shared, enumeration-safe step 1 behind both flows above: look the
  # address up, hand a found account to `notify` (a login PIN, or the
  # registration-attempt notice), and advance to the PIN screen the same way
  # whether or not it was found — the response never depends on existence.
  defp advance_to_pin_screen(conn, email, notify) do
    email = String.downcase(email)

    if user = user_by_email(email), do: notify.(user, email)

    {:ok, put_pin_cookie(reset_login_session(conn), email)}
  end

  # The account owning `email` (case-insensitive), or nil.
  defp user_by_email(email) do
    email = String.downcase(email)

    User
    |> join(:inner, [u], e in assoc(u, :emails))
    |> where([u, e], e.value == ^email)
    |> Repo.one()
  end

  # Reset the session at the start of a login attempt **without dropping it**.
  # We renew (rotate the session id, clearing any previously logged-in user)
  # rather than drop, because the PIN-entry form rendered next carries a CSRF
  # token that is anchored in the session. `logout/1` drops the session, which
  # would discard that token, so the PIN POST would fail `protect_from_forgery`
  # with a 403 ("You are not allowed to view this page"). See issue #759.
  defp reset_login_session(conn) do
    conn
    |> Conn.configure_session(renew: true)
    |> Conn.delete_session(:user_id)
  end

  defp send_login_pin(user, email) do
    user
    |> gen_pin_for("login")
    |> Emailer.login_email(email, user)
    |> deliver_off_request_path(email)
  end

  defp send_registration_attempt_notice(user, email) do
    user
    |> Emailer.registration_attempt_email(email)
    |> deliver_off_request_path(email)
  end

  # Mail off the request path in production: a synchronous SMTP send would make
  # the step-1 response measurably slower for a known address than an unknown
  # one. That timing gap is itself an enumeration oracle, so the send is
  # detached. Tests deliver inline (`config :vutuv, :async_email, false`) so the
  # Swoosh test adapter's message reaches the calling process.
  defp deliver_off_request_path(mail, address) do
    if Application.get_env(:vutuv, :async_email, true) do
      {:ok, _pid} =
        Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn ->
          deliver_and_log(mail, address)
        end)
    else
      deliver_and_log(mail, address)
    end

    :ok
  end

  # Deliver an off-request-path email and never let a failure pass silently:
  # the user is shown "check your email", so a dropped mail must at least be
  # logged (any PIN is already persisted, so we do not roll back).
  defp deliver_and_log(mail, address) do
    case Emailer.deliver(mail) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        Logger.error("Failed to deliver email to #{address}: #{inspect(reason)}")
        error
    end
  end

  def logout(conn) do
    # Revoke this device's server-side session row so it drops out of the
    # owner's signed-in-devices list (issue #794); revoke/1 also kills its live
    # sockets (the embedded shell, /messages, /notifications), so the client
    # reloads, re-mounts through the dropped session and renders the anonymous
    # chrome. Fall back to the raw live_socket_id for a legacy cookie that has
    # no session token yet.
    case Conn.get_session(conn, :session_token) do
      token when is_binary(token) ->
        case Vutuv.Sessions.active_session(token) do
          %Vutuv.Sessions.UserSession{} = session -> Vutuv.Sessions.revoke(session)
          nil -> disconnect_legacy(conn)
        end

      _ ->
        disconnect_legacy(conn)
    end

    conn
    |> Conn.configure_session(drop: true)
    |> Conn.delete_session(:user_id)
  end

  defp disconnect_legacy(conn) do
    if live_socket_id = Conn.get_session(conn, :live_socket_id) do
      Vutuv.Sessions.disconnect(live_socket_id)
    end
  end

  # A genuine first confirmation (email_confirmed? false -> true) is when a sign-up
  # becomes a real member, so the live counter ticks up here, not at
  # registration (issue #781). A legacy `nil`-activated account (already in the
  # count) or an already-activated returning login falls through the second
  # clause and is never re-counted; the cast is a no-op for an already-true row.
  defp activate_user(%User{email_confirmed?: false} = user) do
    activated = do_activate(user)
    MemberCounter.increment()
    activated
  end

  defp activate_user(user), do: do_activate(user)

  defp do_activate(user) do
    user
    |> Ecto.Changeset.cast(%{email_confirmed?: true}, [:email_confirmed?])
    |> Repo.update!()
  end

  # How long a login PIN stays valid (also used further down by check_pin/3).
  @pin_expire_time 1800

  # Name of the signed cookie that carries the pending login identity (the typed
  # email) between the email-entry step and the PIN-entry step. Short-lived: it
  # is only valid while a PIN is, so it shares the PIN's expiry window — bumping
  # one without the other would break step 2 of the login flow mid-window.
  @pin_cookie "_vutuv_login_pin"
  @pin_cookie_max_age @pin_expire_time

  # Sign/verify against the endpoint rather than the conn so the token does not
  # depend on the conn having been through the endpoint plug (it has not yet, at
  # the email step). Both resolve to the same `secret_key_base`.
  @token_context VutuvWeb.Endpoint

  defp put_pin_cookie(conn, email) do
    payload = Phoenix.Token.sign(@token_context, pin_cookie_salt(), email)

    conn
    |> Conn.delete_resp_cookie(@pin_cookie, max_age: @pin_cookie_max_age)
    |> Conn.put_resp_cookie(@pin_cookie, payload, max_age: @pin_cookie_max_age)
  end

  @doc """
  Reads and verifies the signed login-identity cookie, returning the email it
  carries or `nil` when the cookie is absent, tampered with, or expired.
  """
  def read_pin_cookie(%{cookies: %{@pin_cookie => payload}}) do
    case Phoenix.Token.verify(@token_context, pin_cookie_salt(), payload,
           max_age: @pin_cookie_max_age
         ) do
      {:ok, email} -> email
      _ -> nil
    end
  end

  def read_pin_cookie(_conn), do: nil

  @doc "Drops the login-identity cookie (after a successful login or lockout)."
  def delete_pin_cookie(conn) do
    Conn.delete_resp_cookie(conn, @pin_cookie, max_age: @pin_cookie_max_age)
  end

  defp pin_cookie_salt do
    Application.fetch_env!(:vutuv, VutuvWeb.Endpoint)[:secret_key_base]
  end

  # ── Login PINs ──
  # (@pin_expire_time is defined next to the PIN cookie above — they share
  # one validity window.)

  @max_attempts 3

  @doc """
  Mints (or refreshes) the single one-time PIN for a `(user, type)` pair and
  returns the **plaintext** PIN so it can be emailed. Only the peppered, salted
  hash is persisted. `payload` carries flow-specific data (e.g. the new address
  for an email change).
  """
  def gen_pin_for(user, type, payload \\ nil) do
    pin = gen_pin()
    salt = :crypto.strong_rand_bytes(16)

    # A single upsert: a select-then-insert would race with itself (two
    # concurrent first mints for the same (user, type) both see "no row" and
    # the loser's INSERT blows up on the unique index).
    %LoginPin{user_id: user.id}
    |> LoginPin.changeset(%{
      type: type,
      payload: payload,
      minted_at: NaiveDateTime.utc_now(:second),
      consumed_at: nil,
      pin_hash: hash_pin(pin, salt),
      pin_salt: salt,
      pin_login_attempts: 0
    })
    |> Repo.insert!(
      on_conflict:
        {:replace,
         [
           :payload,
           :minted_at,
           :consumed_at,
           :pin_hash,
           :pin_salt,
           :pin_login_attempts,
           :updated_at
         ]},
      conflict_target: [:user_id, :type]
    )

    pin
  end

  # A 6-digit PIN drawn from cryptographically strong randomness. `:rand` is a
  # non-cryptographic PRNG, so it must not be used here (issue #759 C.1).
  defp gen_pin do
    strong_uniform(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  # Uniform integer in `0..bound-1` from `:crypto.strong_rand_bytes`, rejection
  # sampled so the modulo reduction adds no bias.
  defp strong_uniform(bound) do
    span = 0x1_0000_0000
    limit = span - rem(span, bound)
    n = :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned()

    if n < limit, do: rem(n, bound), else: strong_uniform(bound)
  end

  # A 6-digit PIN has only ~20 bits of entropy, so a fast hash (even salted) is
  # crackable offline against a leaked table in well under a second. The pepper
  # (a 256-bit server-side secret held outside the DB) puts that brute force out
  # of reach; the per-PIN salt kills precomputation and cross-row equality even
  # if the pepper also leaks. See issue #759 C.2.
  defp hash_pin(pin, salt) do
    :crypto.mac(:hmac, :sha256, pepper(), salt <> pin)
    |> Base.encode16(case: :lower)
  end

  # Dedicated pepper derived from `secret_key_base` with domain separation, so it
  # never equals the raw secret and lives outside the database.
  defp pepper do
    secret = Application.fetch_env!(:vutuv, VutuvWeb.Endpoint)[:secret_key_base]
    :crypto.hash(:sha256, "vutuv/login_pin/pepper/v1" <> secret)
  end

  defp expire_pin(login_pin) do
    login_pin
    |> LoginPin.changeset(%{minted_at: nil})
    |> Repo.update!()
  end

  # A one-time PIN is spent the moment it verifies. We stamp *when* rather than
  # only nulling `minted_at` (which also marks a timeout or a lockout), so a
  # re-submission can be reported as "already used" instead of the misleading
  # "PIN expired" a member saw right after a successful login (issue #839).
  defp mark_consumed(login_pin) do
    login_pin
    |> LoginPin.changeset(%{consumed_at: NaiveDateTime.utc_now(:second)})
    |> Repo.update!()
  end

  defp consumed?(%{consumed_at: nil}), do: false
  defp consumed?(%{consumed_at: _}), do: true

  defp pin_expired?(%{minted_at: nil}), do: true

  defp pin_expired?(%{minted_at: date_time}) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), date_time, :second) > @pin_expire_time
  end

  # Prod runs at Logger level :error, so these surface only in dev/staging — but
  # they record *why* a PIN was turned away (never the PIN or the address) so a
  # future report like issue #839 is diagnosable without guessing.
  defp log_pin_rejected(%LoginPin{} = login_pin, reason) do
    Logger.info(
      "login_pin rejected: reason=#{reason} type=#{login_pin.type} user_id=#{login_pin.user_id}"
    )
  end

  # A registration mints the account and its first "login" PIN in the same
  # request, so their `inserted_at` land within seconds of each other. A plain
  # login by an existing (e.g. legacy) member also mints a "login" PIN, but
  # against an account created long before — so requiring the PIN to have been
  # created *alongside* the account is what tells an abandoned registration
  # apart from an established member who merely failed to log in. We must never
  # delete the latter. The window is generous against request latency yet still
  # astronomically smaller than the years-apart gap of any legacy account.
  @registration_pin_window_seconds 300

  @doc """
  Deletes `user` and everything that belongs to them — a clean, complete
  teardown, the single entry point both the confirmed account-deletion flow
  and the unconfirmed-registration sweep go through.

  Most rows are removed by the database `ON DELETE` cascade (or `SET NULL` for
  the records that deliberately outlive their author: sent messages and
  replies to a now-deleted post). Two things the cascade cannot do are handled
  here:

    * **On-disk files.** Post-image files and the avatar / cover trees live on
      disk, not in a table, so the cascade never touches them. Their tokens
      and paths are collected *before* the delete and removed *after* it
      commits, so a rolled-back delete never strands the account without its
      files.
    * **Cascade ordering.** The user's posts are deleted first, inside the
      transaction. The audience-Groups feature is gone, but its legacy
      `post_denials.group_id` column (and its RESTRICT FK to `groups`) is kept
      for one N-1 deploy, so clearing the user's posts before the `groups`
      cascade keeps any stale group-denial row from blocking the delete.

  Returns `{:ok, user}`.
  """
  def delete_user(%User{} = user) do
    image_tokens =
      Repo.all(from(i in Vutuv.Posts.PostImage, where: i.user_id == ^user.id, select: i.token))

    # The user's link previews: the urls rows cascade with the account, but
    # their screenshot files (keyed by url id) would be orphaned otherwise.
    # Only the id is needed — Screenshot.delete/1 keys its dirs off it.
    url_ids =
      Repo.all(from(u in Vutuv.Profiles.Url, where: u.user_id == ^user.id, select: %{id: u.id}))

    # Captured before the delete: once the account is gone so are its follow
    # edges, so the recipients of the "post gone" broadcasts can't be looked up
    # afterwards. See Vutuv.Posts.deletion_targets_for_user/1.
    post_targets = Vutuv.Posts.deletion_targets_for_user(user.id)

    # The moderation cases cascade with the account; their on-disk evidence
    # screenshots would be orphaned otherwise.
    evidence_case_ids =
      Repo.all(
        from(c in Moderation.Case,
          where: c.owner_id == ^user.id and not is_nil(c.evidence_screenshot),
          select: c.id
        )
      )

    # Kill every device's live sockets before the cascade removes the session
    # rows (after which their per-session topics are unknowable), so open tabs
    # drop the logged-in chrome at once instead of on their next reload.
    Vutuv.Sessions.disconnect_user(user.id)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.delete_all(from(p in Vutuv.Posts.Post, where: p.user_id == ^user.id))
        Repo.delete!(user)
      end)

    Enum.each(image_tokens, &Vutuv.PostImageStore.delete/1)
    Enum.each(url_ids, &Vutuv.Screenshot.delete/1)
    Moderation.EvidenceScreenshot.delete_for_cases(evidence_case_ids)
    Vutuv.Avatar.delete(user)
    Vutuv.Cover.delete(user)

    # Tell open feeds and action bars the posts are gone, and tick down the
    # reply counters on any surviving parents the account had replied to.
    Enum.each(
      post_targets.post_ids,
      &Vutuv.Posts.broadcast_post_deleted(&1, post_targets.follower_ids)
    )

    Enum.each(post_targets.reply_parent_ids, &Vutuv.Posts.broadcast_reply_count/1)

    {:ok, user}
  end

  @doc """
  Admin-initiated deletion of `user`. Snapshots the account's identifying
  details (name, @handle, id, every email address and phone number, post count,
  join date) **before** the cascade removes them, deletes the account and
  everything it owns through `delete_user/1` (which sends the member no email),
  then mails the operator a record of what was deleted and the exact deletion
  timestamp (`Vutuv.Notifications.Emailer.account_deleted_notice/1`).

  This is the entry point the admin "delete account" page uses. The member is
  never notified; only the operator is. Returns `{:ok, user}`.
  """
  def admin_delete_user(%User{} = user) do
    snapshot = deletion_snapshot(user)
    {:ok, user} = delete_user(user)

    snapshot
    |> Map.put(:deleted_at, DateTime.utc_now())
    |> Emailer.account_deleted_notice()
    |> Emailer.deliver()

    {:ok, user}
  end

  @doc """
  Reverses a moderation removal (the counterpart of
  `Vutuv.Moderation.remove_owner/4` and the report auto-freeze): clears
  `deactivated_at`, `frozen_at` and the internal `moderation_reason`, so a
  wrongly-removed member (e.g. a false spam call) becomes visible and can log in
  again. The strike ladder's `suspended_until` is deliberately left untouched —
  that is a separate consequence with its own expiry. Returns `{:ok, user}`.
  """
  def admin_restore_user(%User{} = user) do
    {_count, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        set: [deactivated_at: nil, frozen_at: nil, moderation_reason: nil]
      )

    {:ok, Repo.get!(User, user.id)}
  end

  # The account details the operator email records, read while the account still
  # exists (the cascade in delete_user/1 removes these rows moments later).
  defp deletion_snapshot(%User{} = user) do
    %{
      id: user.id,
      name: VutuvWeb.UserHelpers.full_name(user),
      username: user.username,
      emails: Repo.all(from(e in Email, where: e.user_id == ^user.id, select: e.value)),
      phone_numbers:
        Repo.all(
          from(p in Vutuv.Profiles.PhoneNumber, where: p.user_id == ^user.id, select: p.value)
        ),
      post_count:
        Repo.aggregate(from(p in Vutuv.Posts.Post, where: p.user_id == ^user.id), :count),
      joined_at: user.inserted_at
    }
  end

  # How long after sign-up an unconfirmed registration is swept.
  @unconfirmed_registration_max_age_minutes 60

  @doc """
  Deletes accounts that registered but never confirmed their PIN (so they are
  still `email_confirmed?: false`) once they are older than `max_age_minutes`.

  Only accounts whose first "login" PIN was minted alongside the account itself
  are touched, so this never reaps a legacy member who only ever failed a login
  (see `@registration_pin_window_seconds`), nor an unconfirmed account that
  never went through the new sign-up form (it would have no such PIN). Each row
  is re-checked as still unconfirmed at delete time and removed with the same
  cascading `Repo.delete!/1` the confirmed account-deletion flow uses. Returns
  the number of accounts deleted.
  """
  def delete_unconfirmed_registrations(
        max_age_minutes \\ @unconfirmed_registration_max_age_minutes
      ) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -max_age_minutes * 60)
    window = @registration_pin_window_seconds

    from(u in User,
      join: p in LoginPin,
      on: p.user_id == u.id and p.type == "login",
      where:
        u.email_confirmed? == false and u.inserted_at < ^cutoff and
          p.inserted_at >= datetime_add(u.inserted_at, ^(-window), "second") and
          p.inserted_at <= datetime_add(u.inserted_at, ^window, "second")
    )
    |> Repo.all()
    |> Enum.count(&delete_if_still_unconfirmed/1)
  end

  # Re-load and guard before deleting: a login could have confirmed the account
  # between the sweep's read and now, so only delete while still unactivated.
  defp delete_if_still_unconfirmed(%User{id: id}) do
    case Repo.get(User, id) do
      %User{email_confirmed?: false} = user ->
        delete_user(user)
        true

      _ ->
        false
    end
  end

  @doc """
  Verifies a one-time PIN.

  Two ways in: pass a `%User{}` for the authenticated email-change and
  account-deletion flows (identity comes from the session), or pass the typed
  email for `"login"` (identity is carried by the signed cookie).

  Returns `{:ok, user}` for login/delete, `{:ok, payload, user}` for the
  email-change flow (where `payload` is the new address), `{:error, message}` on a
  wrong PIN, `{:expired, message}` once the PIN has timed out, or `:lockout`
  after too many wrong attempts.
  """
  def check_pin(%User{} = user, pin, type) do
    Repo.one(from(m in LoginPin, where: m.user_id == ^user.id and m.type == ^type))
    |> verify_pin(pin)
  end

  def check_pin(email, pin, "login") when is_binary(email) do
    result =
      Repo.one(
        from(m in LoginPin,
          join: u in assoc(m, :user),
          join: e in assoc(u, :emails),
          where: e.value == ^email and m.type == ^"login"
        )
      )
      |> verify_pin(pin)

    # The PIN arrived by mail and was typed back: delivery to this address
    # provably works, so a bounce-set undeliverable mark is stale. If the
    # account was frozen as unreachable, a working address thaws it.
    with {:ok, user} <- result do
      Bounces.clear(email)
      if user.unreachable_at, do: Deliverability.reassess_user(user)
    end

    result
  end

  @doc """
  Step 2 of the login, the code the visitor typed into the PIN field: first
  checked as the emailed PIN, then (issue #912) as one of the member's
  alternative login codes — a code from their authenticator app or an unused
  code from their one-time code list (`Vutuv.LoginCodes`).

  Alternate codes only ever *add* a success path: on any alternate failure
  this returns exactly what the PIN check returned, so the error messages,
  the attempt counters, the lockout and the enumeration-safety of the PIN
  flow are unchanged (an unknown address still reads as a plain wrong PIN).
  A valid alternate code even after the emailed PIN expired or locked out is
  deliberate — it proves a strong enrolled credential, not a lucky guess
  (~39-bit codes / a replay-proof TOTP vs the 6-digit PIN the lockout guards).
  """
  def check_login_code(email, code) when is_binary(email) do
    case check_pin(email, code, "login") do
      {:ok, _user} = ok -> ok
      fallback -> redeem_alternate_code(email, code, fallback)
    end
  end

  defp redeem_alternate_code(email, code, fallback) do
    with %User{} = user <- user_by_email(email),
         :ok <- LoginCodes.redeem_login_code(user, code) do
      # An alternate-code login ends the outstanding emailed PIN: the member
      # is in, so the PIN still sitting in their inbox must not stay live.
      # (No Bounces.clear/1 here — unlike a typed-back PIN, an alternate code
      # proves nothing about email deliverability.)
      consume_outstanding_login_pin(user)
      {:ok, user}
    else
      _ -> fallback
    end
  end

  defp consume_outstanding_login_pin(user) do
    case Repo.one(from(m in LoginPin, where: m.user_id == ^user.id and m.type == ^"login")) do
      %LoginPin{consumed_at: nil} = pin -> mark_consumed(pin)
      _ -> :ok
    end
  end

  @doc """
  Records a failed login-PIN attempt for `email` and reports whether that
  identity is now locked out (`:ok` while under the limit, `:locked` once
  the same `@max_attempts` threshold the per-PIN DB counter uses is hit).

  This exists so an address **without** an account locks out after the same
  number of wrong PINs as a real one. The per-PIN `pin_login_attempts`
  lockout only exists for a real account's `LoginPin` row, so on its own it
  would tell an attacker which addresses are registered (a known address
  eventually answers "too many attempts", an unknown one never does). The
  counter is server-side (an ETS window keyed by the signed-cookie email,
  not a replayable cookie or a per-account row) and shares the PIN's
  lifetime as its window, so it cannot be evaded by dropping a cookie and
  mirrors the DB lockout's reset cadence.
  """
  def record_login_pin_failure(email) when is_binary(email) do
    key = {:login_pin_lockout, String.downcase(email)}

    # `hit/3` reports `:rate_limited` once the count exceeds the limit, so a
    # limit of `@max_attempts - 1` locks on exactly the @max_attempts-th
    # failure — the same attempt the DB counter locks on.
    case Vutuv.RateLimiter.hit(key, @max_attempts - 1, @pin_expire_time * 1000) do
      :ok -> :ok
      {:error, :rate_limited} -> :locked
    end
  end

  # No PIN row for this identity. For the login flow this is also what an
  # unknown email reaches after step 1's identical PIN screen, so it must
  # read exactly like a wrong PIN — never "no such account".
  defp verify_pin(nil, _pin) do
    {:error, Gettext.gettext(VutuvWeb.Gettext, "Incorrect PIN")}
  end

  defp verify_pin(%LoginPin{} = login_pin, pin) do
    cond do
      # Checked before expiry and before re-validating: a PIN that was already
      # used successfully must never be replayed, and a duplicate submission of
      # it (a double-tap or back-navigation of the classic PIN form) reads as
      # "already used", not "expired" — the member had in fact just logged in
      # (issue #839).
      consumed?(login_pin) ->
        log_pin_rejected(login_pin, "already_used")
        {:already_used, Gettext.gettext(VutuvWeb.Gettext, "This PIN has already been used.")}

      pin_expired?(login_pin) ->
        expire_pin(login_pin)
        log_pin_rejected(login_pin, "expired")
        {:expired, Gettext.gettext(VutuvWeb.Gettext, "PIN expired")}

      valid_pin?(login_pin, pin) ->
        mark_consumed(login_pin)
        pin_response(login_pin)

      true ->
        record_failed_attempt(login_pin)
    end
  end

  # Constant-time comparison of the peppered hashes (issue #759 C.2). A plain
  # `==` would leak timing information about the stored hash.
  defp valid_pin?(%LoginPin{pin_hash: stored, pin_salt: salt}, pin)
       when is_binary(stored) and is_binary(salt) and is_binary(pin) do
    Plug.Crypto.secure_compare(stored, hash_pin(pin, salt))
  end

  defp valid_pin?(_login_pin, _pin), do: false

  # Records (increments) a failed PIN attempt and locks out at @max_attempts.
  defp record_failed_attempt(login_pin) do
    attempts = login_pin.pin_login_attempts + 1

    if attempts >= @max_attempts do
      expire_pin(login_pin)
      :lockout
    else
      login_pin
      |> LoginPin.changeset(%{pin_login_attempts: attempts})
      |> Repo.update!()

      {:error, Gettext.gettext(VutuvWeb.Gettext, "Incorrect PIN")}
    end
  end

  defp pin_response(%LoginPin{payload: nil, user_id: user_id}) do
    {:ok, Repo.get(User, user_id)}
  end

  defp pin_response(%LoginPin{payload: payload, user_id: user_id}) do
    {:ok, payload, Repo.get(User, user_id)}
  end

  # ── User CRUD ──

  @doc """
  The authoritative "number of members" the landing-page counter reconciles
  against: confirmed members only. Never-confirmed registrations
  (`email_confirmed? == false`) are excluded so the advertised total matches every
  other "real member" gate (followers, tags, endorsements); a legacy
  `nil`-activated account still counts (issue #781).
  """
  def count_users do
    Repo.aggregate(
      from(u in User, where: account_confirmed_row(u)),
      :count
    )
  end

  @doc """
  How many entries the member has in each profile-content section, for the
  settings hub's per-row counts ("Work experience · 7"). One `union_all` round
  trip instead of eight aggregates, in the house style of the profile's totals.
  Returns a map keyed by section:

      %{work_experiences: 7, educations: 0, urls: 3, social_media_accounts: 5,
        emails: 2, phone_numbers: 1, addresses: 1, tags: 9}
  """
  def profile_section_counts(%User{id: user_id}) do
    sections = [
      {Vutuv.Profiles.WorkExperience, "work_experiences"},
      {Vutuv.Profiles.Education, "educations"},
      {Vutuv.Profiles.Qualification, "qualifications"},
      {Vutuv.Profiles.Language, "languages"},
      {Vutuv.Profiles.Url, "urls"},
      {Vutuv.Profiles.SocialMediaAccount, "social_media_accounts"},
      {Email, "emails"},
      {Vutuv.Profiles.PhoneNumber, "phone_numbers"},
      {Vutuv.Profiles.Address, "addresses"},
      {Vutuv.Tags.UserTag, "tags"}
    ]

    query =
      sections
      |> Enum.map(fn {schema, section} -> section_count(schema, section, user_id) end)
      |> Enum.reduce(fn q, acc -> union_all(acc, ^q) end)

    query
    |> Repo.all()
    |> Map.new(fn %{section: section, n: n} -> {String.to_existing_atom(section), n} end)
  end

  defp section_count(schema, section, user_id) do
    from(row in schema,
      where: row.user_id == ^user_id,
      select: %{section: type(^section, :string), n: count(row.id)}
    )
  end

  @doc """
  The user behind a current profile slug, or nil. Only resolves the *active*
  slug (links rendered now), not retired ones — those stay a controller-plug
  concern (`VutuvWeb.Plug.ResolveSlug`).
  """
  def get_user_by_username(slug) when is_binary(slug) do
    Repo.get_by(User, username: slug)
  end

  @doc """
  Grants admin rights to the member behind a username or email address.

  `admin?` is deliberately never castable through any form or the API, so this
  is the one code path that sets it — called from the command line when an
  installation mints its (first) admin: `mix vutuv.admin.promote <handle>` in
  development, `bin/vutuv eval 'Vutuv.Release.promote_admin("<handle>")'` on a
  production release. Idempotent.
  """
  def promote_admin(identifier) when is_binary(identifier) do
    case get_user_by_handle_or_email(identifier) do
      nil -> {:error, :not_found}
      user -> user |> Ecto.Changeset.change(admin?: true) |> Repo.update()
    end
  end

  @doc """
  Resolves a member from a free-typed identifier — a username (with or without a
  leading `@`) or one of their email addresses — or `nil` when nothing matches.
  The one lookup admins type a member into: `promote_admin/1` and the
  honor tag roster (`VutuvWeb.Admin.TagMemberController`) share it, so
  "give @handle the tag" and "make handle an admin" accept the same input.
  """
  def get_user_by_handle_or_email(identifier) when is_binary(identifier) do
    identifier =
      identifier |> String.trim() |> String.trim_leading("@") |> String.downcase()

    get_user_by_username(identifier) || get_user_by_email_value(identifier)
  end

  defp get_user_by_email_value(value) do
    Repo.one(
      from(u in User,
        join: e in assoc(u, :emails),
        where: e.value == ^value,
        limit: 1
      )
    )
  end

  @doc """
  Resolves many usernames to their members in **one** query, keyed by the
  lowercased username. Powers the `@handle` mention links the Markdown renderer
  writes (`VutuvWeb.Markdown`), so a post or message with several mentions costs
  a single lookup. Only currently-active usernames resolve (like
  `get_user_by_username/1`); unknown handles are simply absent from the map.

  The selected struct carries only the fields a mention needs — the username
  (for the `/:slug` href) and the name parts (for the hover tooltip).
  """
  def get_users_by_usernames(usernames) when is_list(usernames) do
    normalized = usernames |> Enum.map(&String.downcase/1) |> Enum.uniq()

    case normalized do
      [] ->
        %{}

      names ->
        from(u in User,
          where: u.username in ^names,
          select:
            struct(u, [:username, :first_name, :last_name, :honorific_prefix, :honorific_suffix])
        )
        |> Repo.all()
        |> Map.new(&{&1.username, &1})
    end
  end

  @doc """
  One-off backfill that brings every legacy handle into line with the
  Twitter-style rule (`User.username_changeset/2`: `^[a-z0-9_]+$`, max 15
  chars) - chiefly the dotted and over-length imports from the old vutuv.

  For each member whose current `username` fails the charset rule, it
  regenerates a valid handle from the member's name (so `Oliver Gassner` ->
  `oliver_gassner`) and preserves the retired handle in `users.legacy_username`,
  so the old handle is never lost and the old profile URL 301s to the new one
  (`VutuvWeb.Plug.UserResolveSlug`). Returns the number of members renamed.

  **Uniqueness is guaranteed in code, not left to the DB constraint.** Every
  handle already in use (the untouched valid accounts) plus every handle minted
  during this run are held in one set; the plain name-handle is used only when
  it is free, otherwise a 6-char stem plus a random number is re-rolled until it
  lands on a free handle. So two members with the same name (or whose names
  normalize the same) can never collide on the same new handle - the run never
  trips the `users.username` unique index and so never aborts mid-migration.

  Idempotent: a regenerated handle is itself charset-valid, so a second run
  finds nothing left to rename. Referenced by the `NormalizeLegacyUsernames`
  data migration; this is a system correction, not a member action, so it
  deliberately bypasses the username-change quota ledger. (A member whose name
  is a single letter regenerates to a 1-2 char handle: charset-valid and
  resolvable, just shy of the 3-char editor minimum, exactly as registration
  would mint it today.)
  """
  def normalize_legacy_usernames do
    reserved = MapSet.new(ReservedSlugs.list())

    # Handles we must not collide with: every already-valid handle. The invalid
    # ones are being replaced, and a freshly minted handle (no dots, <=15 chars)
    # can never equal one of them anyway, so they do not constrain us.
    taken =
      from(u in User, where: fragment("? ~ '^[a-z0-9_]+$'", u.username), select: u.username)
      |> Repo.all()
      |> MapSet.new()

    invalid =
      from(u in User,
        where: fragment("? !~ '^[a-z0-9_]+$'", u.username),
        select: %{id: u.id, old: u.username, first: u.first_name, last: u.last_name}
      )
      |> Repo.all()

    {_taken, renamed} =
      Enum.reduce(invalid, {taken, 0}, fn row, {taken, renamed} ->
        new_username = unique_legacy_handle("#{row.first} #{row.last}", taken, reserved)

        {1, _} =
          Repo.update_all(from(u in User, where: u.id == ^row.id),
            set: [username: new_username, legacy_username: row.old]
          )

        {MapSet.put(taken, new_username), renamed + 1}
      end)

    renamed
  end

  # A handle guaranteed free against `taken` and never a reserved word: the
  # name's plain handle when that is free, otherwise a stem plus a random number
  # re-rolled until it lands on a free handle.
  defp unique_legacy_handle(name, taken, reserved) do
    base = Vutuv.SlugHelpers.handleize(name)

    if base != "" and not MapSet.member?(taken, base) and not MapSet.member?(reserved, base) do
      base
    else
      stem = base |> String.slice(0, 6) |> String.trim("_")

      Stream.repeatedly(fn -> random_handle(stem) end)
      |> Enum.find(fn handle ->
        not MapSet.member?(taken, handle) and not MapSet.member?(reserved, handle)
      end)
    end
  end

  # `stem_<random>`, trimmed so an empty stem yields just the number, and within
  # the 15-char limit (stem <= 6, "_", up to 8 random digits). Crypto-strong so
  # the draws do not depend on a process seed.
  defp random_handle(stem) do
    number = :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned() |> rem(100_000_000)
    String.trim_leading("#{stem}_#{number}", "_")
  end

  # The plain profile fields a member may edit about themselves. The API's
  # PATCH /me writes through this list; the username (quota'd,
  # Twitter-validated), email addresses (PIN-verified identities) and
  # account flags (email_confirmed?, notification_emails?) are deliberately not
  # on it.
  @profile_fields ~w(headline first_name last_name middle_name nickname
                     honorific_prefix honorific_suffix gender birthdate
                     locale noindex? noai?)

  @doc """
  Updates only the plain profile fields (see `@profile_fields`) — the
  contract behind `PATCH /api/2.0/me`. Anything else in `attrs` is ignored,
  so callers can pass request params through untouched.
  """
  def update_profile(%User{} = user, attrs) do
    update_user(user, Map.take(attrs, @profile_fields))
  end

  def update_user(%User{} = user, attrs) do
    changeset =
      user
      |> Repo.preload(:search_terms)
      |> User.changeset(attrs)
      |> maybe_rebuild_search_terms()

    with {:ok, user} <- Repo.update(changeset) do
      {:ok, store_pending_images(user, attrs)}
    end
  end

  @doc """
  Pins `work_experience` as the member's profile job title (issue #833): the
  title/organization the profile header, listing rows, meta description,
  JSON-LD and every agent format lead with, instead of the automatic
  `VutuvWeb.UserHelpers.current_job/1` heuristic.

  `work_experience` must belong to `user` (the caller resolves it owner-scoped);
  a foreign one is rejected rather than pinned. `profile_work_experience_id` is
  set programmatically here, never cast from the profile form.
  """
  def pin_profile_work_experience(%User{id: user_id} = user, %WorkExperience{
        id: we_id,
        user_id: user_id
      }) do
    user
    |> Ecto.Changeset.change(profile_work_experience_id: we_id)
    # Guards against a race where the experience is deleted between the owner
    # resolution and this write: the FK constraint fails cleanly instead of
    # persisting a dangling pointer.
    |> Ecto.Changeset.foreign_key_constraint(:profile_work_experience_id)
    |> Repo.update()
  end

  def pin_profile_work_experience(%User{}, %WorkExperience{}), do: {:error, :not_owner}

  @doc """
  Clears the member's pinned profile job title, so it falls back to the
  automatic `VutuvWeb.UserHelpers.current_job/1` heuristic again (issue #833).
  """
  def unpin_profile_work_experience(%User{} = user) do
    user
    |> Ecto.Changeset.change(profile_work_experience_id: nil)
    |> Repo.update()
  end

  @doc """
  Permanently hides the owner's profile-completion checklist (its × control on
  the profile). The checklist already auto-hides an hour after sign-up; this
  lets a member dismiss it sooner and for good. Set programmatically, so the
  flag stays out of every user-facing changeset.
  """
  def dismiss_onboarding(%User{} = user) do
    user
    |> Ecto.Changeset.change(onboarding_dismissed?: true)
    |> Repo.update()
  end

  # Avatar/cover files are written to disk only AFTER the row commits, so a
  # rolled-back update (a name too long, a constraint, ...) never orphans them
  # (issue #776). User.changeset already validated the uploads in memory; here
  # we store them against the just-committed user (final id + handle, which the
  # served filename embeds) and set the filename, content fingerprint and crop
  # columns in a second write.
  defp store_pending_images(user, attrs) do
    user
    |> store_pending_image(
      :avatar,
      :avatar_crop,
      image_upload(attrs, :avatar),
      crop_param(attrs, "avatar_crop"),
      &Vutuv.Avatar.store/2
    )
    |> store_pending_image(
      :cover_photo,
      :cover_crop,
      image_upload(attrs, :cover_photo),
      crop_param(attrs, "cover_crop"),
      &Vutuv.Cover.store/2
    )
  end

  defp store_pending_image(user, _field, _crop_field, nil, _crop, _store), do: user

  defp store_pending_image(user, field, crop_field, %Plug.Upload{} = upload, crop, store) do
    # The store returns the content fingerprint alongside the filename; the
    # filename, fingerprint and crop are persisted together, putting the row on
    # the fingerprinted scheme (its URL carries the fingerprint in the filename,
    # so no `updated_at`-based `?v=` is needed). The crop is folded into the
    # fingerprint, so re-cropping the same original still yields a fresh, cache-
    # safe URL. The crop column is always reset to the freshly-submitted value:
    # a new upload must not inherit the previous image's crop, and it is persisted
    # so a later re-derive (`Vutuv.Uploads.Regenerator`) re-applies it (see
    # `Vutuv.Uploads.Crop`). A failure of either step (a rare disk/db error after
    # a decode the changeset already proved) keeps the prior image rather than
    # committing columns that point at a file that was never written.
    with {:ok, file_name, fingerprint} <- store.({upload, user}, crop),
         attrs = %{
           field => file_name,
           fingerprint_field(field) => fingerprint,
           crop_field => crop
         },
         {:ok, saved} <- user |> Ecto.Changeset.change(attrs) |> Repo.update() do
      saved
    else
      _ ->
        Logger.warning("#{field} store failed for user ##{user.id}")
        user
    end
  end

  defp fingerprint_field(:avatar), do: :avatar_fingerprint
  defp fingerprint_field(:cover_photo), do: :cover_fingerprint

  # The user-chosen crop rectangle for an image, normalised to its canonical
  # `"x,y,w,h"` form (or nil for no/invalid crop). Only the web form sends it
  # (string keys); internal callers (e.g. the gravatar import) pass atom-keyed
  # attrs with no crop, which Map.get reads as nil — i.e. centered.
  defp crop_param(attrs, key) when is_binary(key) do
    attrs |> Map.get(key) |> Crop.normalize()
  end

  defp image_upload(attrs, field) do
    case attrs do
      %{^field => %Plug.Upload{} = upload} -> upload
      %{} -> string_image_upload(attrs, Atom.to_string(field))
    end
  end

  defp string_image_upload(attrs, key) do
    case attrs do
      %{^key => %Plug.Upload{} = upload} -> upload
      _ -> nil
    end
  end

  # Rebuild the denormalized people-search index whenever the name changes, so
  # the API rename path (PATCH /api/2.0/me) keeps search in sync with the
  # profile — the web edit form already does this in its controller. Built from
  # the changeset's final field values (not the raw params), so a partial
  # update that carries only one name key can't wipe the whole index.
  defp maybe_rebuild_search_terms(changeset) do
    if Ecto.Changeset.get_change(changeset, :first_name) ||
         Ecto.Changeset.get_change(changeset, :last_name) do
      first = Ecto.Changeset.get_field(changeset, :first_name) || ""
      last = Ecto.Changeset.get_field(changeset, :last_name) || ""

      Ecto.Changeset.put_assoc(
        changeset,
        :search_terms,
        SearchTerm.create_search_terms(%{"first_name" => first, "last_name" => last})
      )
    else
      changeset
    end
  end

  def get_user(id), do: Repo.get(User, id)

  @doc """
  Switches one notification-email preference on or off. `field` must be one of
  `User.email_pref_fields/0` (the unsubscribe allowlist), so a tokenized
  one-click unsubscribe link can only ever flip a real email preference, never
  an arbitrary column. Returns `{:error, :invalid_field}` for anything else.
  """
  def set_email_pref(%User{} = user, field, enabled?)
      when is_atom(field) and is_boolean(enabled?) do
    if field in User.email_pref_fields() do
      user
      |> Ecto.Changeset.change(%{field => enabled?})
      |> Repo.update()
    else
      {:error, :invalid_field}
    end
  end

  @doc """
  Sets the viewer's default map service (the one rendered as the primary
  "Open in …" button). `service` must be one of `Vutuv.Maps.service_strings/0`,
  so the click-to-promote endpoint can never write an arbitrary value. A narrow
  changeset, deliberately not `update_user/2`: this fires on every map click, so
  it skips the image-store and search-term rebuild that the full path carries.
  Returns `{:error, :invalid_service}` for anything else.
  """
  def set_default_map_service(%User{} = user, service) when is_binary(service) do
    if Vutuv.Maps.valid_service?(service) do
      user
      |> Ecto.Changeset.change(%{default_map_service: service})
      |> Repo.update()
    else
      {:error, :invalid_service}
    end
  end

  # ── Usernames ──

  @username_change_limit 4
  @username_change_window_days 90

  @doc """
  Renames the account: validates the new handle (`User.username_changeset/2`),
  checks the change quota, and records the change in the `username_changes`
  ledger, all in one transaction. The old handle is simply freed - no
  redirect, no reservation. Returns the changeset on failure (invalid, taken,
  reserved, unchanged, or quota exhausted).
  """
  def update_username(%User{} = user, attrs) do
    changeset =
      user
      |> User.username_changeset(attrs)
      |> validate_username_was_changed()
      |> validate_username_quota(user)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.insert(:change, fn %{user: updated} ->
      %UsernameChange{user_id: user.id, value: updated.username}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} ->
        rebuild_images_for_new_username(user)
        {:ok, user}

      {:error, :user, changeset, _} ->
        {:error, changeset}
    end
  end

  # A username change moves the handle baked into fingerprinted image filenames
  # (`<handle>-<version>-<fp>.avif`), so re-derive avatar and cover under the new
  # handle — off the private original, so it never depends on the old-handle
  # files — before returning, or the slug-in-the-URL would 404. A no-op for
  # images still on the legacy (name/id-based) scheme. Slug changes are
  # rate-limited (4 per 90 days), so the synchronous re-derive is cheap enough.
  defp rebuild_images_for_new_username(user) do
    Vutuv.Avatar.reslug(user)
    Vutuv.Cover.reslug(user)
    :ok
  end

  # Re-submitting the current handle would be a no-op rename that still burns
  # quota and a ledger row - reject it instead.
  defp validate_username_was_changed(changeset) do
    if changeset.valid? and Ecto.Changeset.get_change(changeset, :username) == nil do
      Ecto.Changeset.add_error(changeset, :username, "is already your username")
    else
      changeset
    end
  end

  defp validate_username_quota(changeset, user) do
    case username_change_quota(user) do
      %{remaining: 0} ->
        Ecto.Changeset.add_error(
          changeset,
          :username,
          "can only be changed %{limit} times within %{days} days",
          limit: @username_change_limit,
          days: @username_change_window_days
        )

      _ ->
        changeset
    end
  end

  @doc """
  The user's change quota: `4` changes per rolling `90` days, counted from the
  `username_changes` ledger. `next_change_at` is set once the quota is used up -
  the moment the oldest counted change leaves the window.
  """
  def username_change_quota(%User{id: user_id}) do
    window_start =
      NaiveDateTime.add(NaiveDateTime.utc_now(), -@username_change_window_days * 86_400, :second)

    changes =
      Repo.all(
        from(c in UsernameChange,
          where: c.user_id == ^user_id and c.inserted_at > ^window_start,
          order_by: [desc: c.inserted_at],
          select: c.inserted_at
        )
      )

    used = length(changes)
    remaining = max(@username_change_limit - used, 0)

    next_change_at =
      if remaining == 0 do
        # The quota frees up when the oldest of the counted changes (the
        # limit-th most recent) falls out of the rolling window.
        changes
        |> Enum.at(@username_change_limit - 1)
        |> NaiveDateTime.add(@username_change_window_days * 86_400, :second)
      end

    %{
      used: used,
      remaining: remaining,
      limit: @username_change_limit,
      window_days: @username_change_window_days,
      next_change_at: next_change_at
    }
  end

  @doc "Whether a handle is in use by any member right now."
  def username_taken?(value) when is_binary(value) do
    Repo.exists?(from(u in User, where: u.username == ^value))
  end

  # ── Emails ──

  @doc """
  The user's first email address value (public or not) — the address the
  account-level mails (deletion PIN, verification notice) go to.
  """
  def first_email_value(%User{id: id}) do
    Repo.one(from(e in Email, where: e.user_id == ^id, limit: 1, select: e.value))
  end

  @doc """
  The admin "Verify identity" action: marks the member as `identity_verified?`
  and emails them the confirmation. Reloads the user fresh so a partial listing
  struct (handed in by the admin member browser, which selects only a few
  columns) still carries the `locale` the notice renders in. Returns
  `{:ok, user}` or `{:error, changeset}`. Used by both `Admin.UserController`
  (the legacy POST) and `Admin.UserLive` (the inline button).
  """
  def verify_identity(%User{id: id}) do
    User
    |> Repo.get!(id)
    |> Ecto.Changeset.cast(%{identity_verified?: true}, [:identity_verified?])
    |> Repo.update()
    |> case do
      {:ok, user} ->
        user |> Emailer.verification_notice() |> Emailer.deliver()
        {:ok, user}

      error ->
        error
    end
  end

  # ── Admin member browser (/admin/users) ──

  @admin_users_per_page 50

  # The sortable columns of the member browser, by the `?sort=` value a header
  # link sets. "name" is special-cased (last then first name) in the order_by.
  @admin_user_sort_columns %{
    "joined" => :inserted_at,
    "name" => :last_name,
    "username" => :username,
    "updated" => :updated_at
  }

  # The columns a member-browser row needs: the listing fields (avatar, name
  # parts, slug) plus the timestamps and the status flags the table renders.
  @admin_listing_fields ~w(id first_name last_name honorific_prefix honorific_suffix username
    avatar avatar_fingerprint updated_at inserted_at email_confirmed? admin?
    identity_verified? frozen_at suspended_until deactivated_at unreachable_at
    moderation_reason)a

  @doc "The member-browser page size, shared by the query and the pager."
  def admin_users_per_page, do: @admin_users_per_page

  @doc "The sortable member-browser columns (the `?sort=` values)."
  def admin_user_sort_columns, do: Map.keys(@admin_user_sort_columns)

  @doc """
  Normalizes raw request params into a validated filter map for the member
  browser: `reg` (registration: "pin" PIN-confirmed — the default — / "unconfirmed"
  / "all"), `flag` (account flag: "all" — the default — / "admin" / "verified" /
  "unverified" identity-verification queue / "frozen" / "suspended" / "deactivated"
  / "unreachable" / "spam" moderation-removed), `q` (search term, trimmed), `sort`
  (a known column, default "joined") and `dir` ("asc"/"desc", default "desc", so
  the default landing shows the newest members first). Anything invalid falls
  back to a safe default, so the params can never inject into the query.
  """
  def admin_user_filters(params) when is_map(params) do
    %{
      reg: validated_param(params["reg"], ~w(pin unconfirmed all)) || "pin",
      flag:
        validated_param(
          params["flag"],
          ~w(all admin verified unverified frozen suspended deactivated unreachable spam)
        ) || "all",
      q: normalize_search(params["q"]),
      sort: validated_param(params["sort"], admin_user_sort_columns()) || "joined",
      dir: if(params["dir"] == "asc", do: "asc", else: "desc")
    }
  end

  @doc "How many members match the filters (for the pager)."
  def count_admin_users(filters) do
    filters |> admin_users_base() |> Repo.aggregate(:count)
  end

  @doc """
  One page of the member browser, filtered, searched, sorted and paginated.
  Rows carry only the columns the table renders (`@admin_listing_fields`). `opts`
  may carry `:total` (skip the recount) and `:per_page` (default
  `admin_users_per_page/0`).
  """
  def list_admin_users(filters, params \\ %{}, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @admin_users_per_page)
    total = Keyword.get(opts, :total) || count_admin_users(filters)

    filters
    |> admin_users_base()
    |> order_admin_users(filters)
    |> select([u], struct(u, ^@admin_listing_fields))
    |> Pages.paginate(params, total, per_page)
    |> Repo.all()
  end

  defp admin_users_base(filters) do
    from(u in User)
    |> filter_registration(Map.get(filters, :reg))
    |> filter_flag(Map.get(filters, :flag))
    |> search_members(Map.get(filters, :q))
  end

  defp filter_registration(query, "pin"), do: where(query, [u], u.email_confirmed? == true)

  defp filter_registration(query, "unconfirmed"),
    do: where(query, [u], u.email_confirmed? == false)

  defp filter_registration(query, _all), do: query

  defp filter_flag(query, "admin"), do: where(query, [u], u.admin? == true)
  defp filter_flag(query, "verified"), do: where(query, [u], u.identity_verified? == true)
  defp filter_flag(query, "unverified"), do: where(query, [u], u.identity_verified? != true)
  defp filter_flag(query, "frozen"), do: where(query, [u], not is_nil(u.frozen_at))
  defp filter_flag(query, "suspended"), do: where(query, [u], not is_nil(u.suspended_until))
  defp filter_flag(query, "deactivated"), do: where(query, [u], not is_nil(u.deactivated_at))
  defp filter_flag(query, "unreachable"), do: where(query, [u], not is_nil(u.unreachable_at))
  defp filter_flag(query, "spam"), do: where(query, [u], u.moderation_reason == "spam")
  defp filter_flag(query, _all), do: query

  defp search_members(query, nil), do: query

  defp search_members(query, term) do
    # A typed "@handle" is just the username; drop the leading @ so it matches.
    like = "%" <> escape_like(String.trim_leading(term, "@")) <> "%"

    # Admins routinely need to find an account by its email address (support,
    # moderation). Matched server-side via a subquery — the address is never
    # shown in the listing, so this finds the account without leaking the email.
    by_email = from(e in Email, where: ilike(e.value, ^like), select: e.user_id)

    where(
      query,
      [u],
      name_ilike(u.first_name, u.last_name, ^like) or ilike(u.username, ^like) or
        u.id in subquery(by_email)
    )
  end

  defp order_admin_users(query, %{sort: "name"} = filters) do
    dir = sort_dir(filters)
    from(u in query, order_by: [{^dir, u.last_name}, {^dir, u.first_name}, {^dir, u.id}])
  end

  defp order_admin_users(query, filters) do
    column = Map.get(@admin_user_sort_columns, Map.get(filters, :sort), :inserted_at)
    dir = sort_dir(filters)
    from(u in query, order_by: [{^dir, field(u, ^column)}, {^dir, u.id}])
  end

  defp sort_dir(%{dir: "asc"}), do: :asc
  defp sort_dir(_filters), do: :desc

  defp validated_param(value, allowed) when is_binary(value),
    do: if(value in allowed, do: value, else: nil)

  defp validated_param(_value, _allowed), do: nil
end
