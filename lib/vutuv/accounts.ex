defmodule Vutuv.Accounts do
  @moduledoc """
  The Accounts context. Handles user registration, authentication,
  email management, and slugs.
  """

  import Ecto.Query
  require Logger

  alias Plug.Conn
  alias Vutuv.Accounts.Email
  alias Vutuv.Accounts.LoginPin
  alias Vutuv.Accounts.MemberCounter
  alias Vutuv.Accounts.ReservedSlugs
  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.Accounts.SlugChange
  alias Vutuv.Accounts.User
  alias Vutuv.Moderation
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Repo

  # ── Registration ──

  def register_user(conn, user_params, assocs \\ []) do
    user_params
    |> registration_slug()
    |> user_changeset(conn, user_params, assocs)
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        # The sign-up form's "Your tags" field (the virtual `tag_list`): turn
        # it into real user tags now that the user row exists.
        user_params["tag_list"]
        |> Vutuv.Tags.parse_tag_names()
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
  defp registration_slug(user_params) do
    if user_params["first_name"] != nil or user_params["last_name"] != nil do
      struct = %User{first_name: user_params["first_name"], last_name: user_params["last_name"]}

      Vutuv.SlugHelpers.gen_handle_unique(struct, User, :active_slug, ReservedSlugs.list())
    end
  end

  defp user_changeset(slug_value, conn, user_params, assocs) do
    search_terms = SearchTerm.create_search_terms(user_params)

    changeset =
      User.registration_changeset(%User{}, user_params)
      |> Ecto.Changeset.put_assoc(:search_terms, search_terms)
      |> put_registration_slug(slug_value)
      |> Ecto.Changeset.put_change(:locale, conn.assigns[:locale])

    Enum.reduce([changeset | assocs], fn {type, params}, changeset ->
      Ecto.Changeset.put_assoc(changeset, type, [params])
    end)
  end

  defp put_registration_slug(changeset, nil),
    do: Ecto.Changeset.add_error(changeset, :active_slug, "can't be generated without a name")

  defp put_registration_slug(changeset, slug_value) do
    changeset
    |> Ecto.Changeset.put_change(:active_slug, slug_value)
    # The generator already dodged collisions; this catches the race where two
    # registrations generate the same handle at once.
    |> Ecto.Changeset.unique_constraint(:active_slug)
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
        filename = "/#{user.active_slug}.#{gravatar_extension(content_type)}"
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

    conn
    |> Conn.assign(:current_user, user)
    |> Conn.put_session(:user_id, user.id)
    # The LiveView socket subscribes to this topic on connect; logout (and
    # the stale-session sweep in ConfigureSession) broadcasts "disconnect"
    # on it so live views never outlive the session that mounted them.
    |> Conn.put_session(:live_socket_id, "users_socket:#{user.id}")
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

    user =
      User
      |> join(:inner, [u], e in assoc(u, :emails))
      |> where([u, e], e.value == ^email)
      |> Repo.one()

    if user, do: notify.(user, email)

    {:ok, put_pin_cookie(reset_login_session(conn), email)}
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
    # Kill this session's live sockets (the embedded shell, /messages,
    # /notifications): the client reloads, re-mounts through the dropped
    # session and renders the anonymous chrome.
    if live_socket_id = Conn.get_session(conn, :live_socket_id) do
      VutuvWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> Conn.configure_session(drop: true)
    |> Conn.delete_session(:user_id)
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
      minted_at: NaiveDateTime.from_erl!(:calendar.universal_time()),
      pin_hash: hash_pin(pin, salt),
      pin_salt: salt,
      pin_login_attempts: 0
    })
    |> Repo.insert!(
      on_conflict:
        {:replace, [:payload, :minted_at, :pin_hash, :pin_salt, :pin_login_attempts, :updated_at]},
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

  defp pin_expired?(%{minted_at: nil}), do: true

  defp pin_expired?(%{minted_at: date_time}) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), date_time, :second) > @pin_expire_time
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
    # provably works, so a bounce-set undeliverable mark is stale.
    with {:ok, _user} <- result, do: Vutuv.Notifications.Bounces.clear(email)

    result
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
      pin_expired?(login_pin) ->
        expire_pin(login_pin)
        {:expired, Gettext.gettext(VutuvWeb.Gettext, "PIN expired")}

      valid_pin?(login_pin, pin) ->
        expire_pin(login_pin)
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
    Repo.one(
      from(u in User,
        where: is_nil(u.email_confirmed?) or u.email_confirmed? == true,
        select: count(u.id)
      )
    )
  end

  @doc """
  The user behind a current profile slug, or nil. Only resolves the *active*
  slug (links rendered now), not retired ones — those stay a controller-plug
  concern (`VutuvWeb.Plug.ResolveSlug`).
  """
  def get_user_by_slug(slug) when is_binary(slug) do
    Repo.get_by(User, active_slug: slug)
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

  # Avatar/cover files are written to disk only AFTER the row commits, so a
  # rolled-back update (a name too long, a constraint, ...) never orphans them
  # (issue #776). User.changeset already validated the uploads in memory; here
  # we store them against the just-committed user (final id + name, which the
  # on-disk file name is derived from) and set the column in a second write.
  defp store_pending_images(user, attrs) do
    user
    |> store_pending_image(:avatar, image_upload(attrs, :avatar), &Vutuv.Avatar.store/1)
    |> store_pending_image(:cover_photo, image_upload(attrs, :cover_photo), &Vutuv.Cover.store/1)
  end

  defp store_pending_image(user, _field, nil, _store), do: user

  defp store_pending_image(user, field, %Plug.Upload{} = upload, store) do
    with {:ok, file_name} <- store.({upload, user}),
         {:ok, user} <- user |> Ecto.Changeset.change(%{field => file_name}) |> Repo.update() do
      user
    else
      # The changeset already proved the upload decodes, so this is a rare disk
      # failure; keep the prior image rather than committing a column that
      # points at a file that was never written.
      _ ->
        Logger.warning("#{field} store failed for user ##{user.id}")
        user
    end
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
  Switches non-essential notification email (the unread-message nudge) on or
  off. The off switch is reachable without a login: the signed token in every
  notification email authorizes it (`VutuvWeb.UnsubscribeToken`), so a
  recipient locked out of their account can still stop the mail.
  """
  def set_notification_emails(%User{} = user, enabled?) when is_boolean(enabled?) do
    user
    |> Ecto.Changeset.change(notification_emails?: enabled?)
    |> Repo.update()
  end

  # ── Usernames ──

  @slug_change_limit 4
  @slug_change_window_days 90

  @doc """
  Renames the account: validates the new handle (`User.slug_changeset/2`),
  checks the change quota, and records the change in the `slug_changes`
  ledger, all in one transaction. The old handle is simply freed - no
  redirect, no reservation. Returns the changeset on failure (invalid, taken,
  reserved, unchanged, or quota exhausted).
  """
  def update_active_slug(%User{} = user, attrs) do
    changeset =
      user
      |> User.slug_changeset(attrs)
      |> validate_slug_was_changed()
      |> validate_slug_quota(user)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.insert(:change, fn %{user: updated} ->
      %SlugChange{user_id: user.id, value: updated.active_slug}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  # Re-submitting the current handle would be a no-op rename that still burns
  # quota and a ledger row - reject it instead.
  defp validate_slug_was_changed(changeset) do
    if changeset.valid? and Ecto.Changeset.get_change(changeset, :active_slug) == nil do
      Ecto.Changeset.add_error(changeset, :active_slug, "is already your username")
    else
      changeset
    end
  end

  defp validate_slug_quota(changeset, user) do
    case slug_change_quota(user) do
      %{remaining: 0} ->
        Ecto.Changeset.add_error(
          changeset,
          :active_slug,
          "can only be changed %{limit} times within %{days} days",
          limit: @slug_change_limit,
          days: @slug_change_window_days
        )

      _ ->
        changeset
    end
  end

  @doc """
  The user's change quota: `4` changes per rolling `90` days, counted from the
  `slug_changes` ledger. `next_change_at` is set once the quota is used up -
  the moment the oldest counted change leaves the window.
  """
  def slug_change_quota(%User{id: user_id}) do
    window_start =
      NaiveDateTime.add(NaiveDateTime.utc_now(), -@slug_change_window_days * 86_400, :second)

    changes =
      Repo.all(
        from(c in SlugChange,
          where: c.user_id == ^user_id and c.inserted_at > ^window_start,
          order_by: [desc: c.inserted_at],
          select: c.inserted_at
        )
      )

    used = length(changes)
    remaining = max(@slug_change_limit - used, 0)

    next_change_at =
      if remaining == 0 do
        # The quota frees up when the oldest of the counted changes (the
        # limit-th most recent) falls out of the rolling window.
        changes
        |> Enum.at(@slug_change_limit - 1)
        |> NaiveDateTime.add(@slug_change_window_days * 86_400, :second)
      end

    %{
      used: used,
      remaining: remaining,
      limit: @slug_change_limit,
      window_days: @slug_change_window_days,
      next_change_at: next_change_at
    }
  end

  @doc "Whether a handle is in use by any member right now."
  def slug_taken?(value) when is_binary(value) do
    Repo.exists?(from(u in User, where: u.active_slug == ^value))
  end

  # ── Emails ──

  @doc """
  The user's first email address value (public or not) — the address the
  account-level mails (deletion PIN, verification notice) go to.
  """
  def first_email_value(%User{id: id}) do
    Repo.one(from(e in Email, where: e.user_id == ^id, limit: 1, select: e.value))
  end
end
