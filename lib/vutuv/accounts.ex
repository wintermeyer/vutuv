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
  alias Vutuv.Accounts.ReservedSlugs
  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.Accounts.Slug
  alias Vutuv.Accounts.User
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Repo

  # ── Registration ──

  def register_user(conn, user_params, assocs \\ []) do
    user_params
    |> slug_changeset()
    |> user_changeset(conn, user_params, assocs)
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        user = Repo.preload(user, user_tags: [:tag])
        maybe_fetch_gravatar(user)
        {:ok, user}

      error ->
        error
    end
  end

  defp slug_changeset(user_params) do
    if user_params["first_name"] != nil or user_params["last_name"] != nil do
      struct = %User{first_name: user_params["first_name"], last_name: user_params["last_name"]}

      slug_value =
        Vutuv.SlugHelpers.gen_slug_unique(struct, Slug, :value, ReservedSlugs.list())

      Slug.changeset(%Slug{}, %{value: slug_value})
    else
      Slug.changeset(%Slug{}, %{value: "invalid"})
      |> Ecto.Changeset.add_error(:value, "Invalid slug")
    end
  end

  defp user_changeset(slug_changeset, conn, user_params, assocs) do
    search_terms = SearchTerm.create_search_terms(user_params)

    changeset =
      User.registration_changeset(%User{}, user_params)
      |> Ecto.Changeset.put_assoc(:slugs, [slug_changeset])
      |> Ecto.Changeset.put_assoc(:search_terms, search_terms)
      |> Ecto.Changeset.put_change(:active_slug, slug_changeset.changes[:value])
      |> Ecto.Changeset.put_change(:locale, conn.assigns[:locale])

    Enum.reduce([changeset | assocs], fn {type, params}, changeset ->
      Ecto.Changeset.put_assoc(changeset, type, [params])
    end)
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
        filename = "/#{user.active_slug}.#{String.replace(content_type, "image/", "")}"
        path = System.tmp_dir()

        upload = %Plug.Upload{
          content_type: content_type,
          filename: filename,
          path: path <> filename
        }

        File.write(path <> filename, body)

        user
        |> Repo.preload([:slugs, :oauth_providers, :emails])
        |> User.changeset(%{avatar: upload})
        |> Repo.update()

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

  # ── Authentication ──

  def login(conn, user) do
    user = validate_user(user)

    conn
    |> Conn.assign(:current_user, user)
    |> Conn.put_session(:user_id, user.id)
    |> Conn.configure_session(renew: true)
  end

  def login_by_email(conn, email) do
    email = String.downcase(email)

    User
    |> join(:inner, [u], e in assoc(u, :emails))
    |> where([u, e], e.value == ^email)
    |> Repo.one()
    |> send_login_email(reset_login_session(conn), email)
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

  defp send_login_email(nil, conn, _), do: {:error, :not_found, conn}

  defp send_login_email(user, conn, email) do
    user
    |> gen_pin_for("login")
    |> Emailer.login_email(email, user)
    |> deliver_login_email(email)

    {:ok, put_pin_cookie(conn, email)}
  end

  # Deliver a login email and never let a delivery failure pass silently:
  # the user is shown "check your email", so a dropped mail must at least be
  # logged (the PIN is already persisted, so we do not roll back).
  defp deliver_login_email(mail, address) do
    case Emailer.deliver(mail) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        Logger.error("Failed to deliver login email to #{address}: #{inspect(reason)}")
        error
    end
  end

  def logout(conn) do
    conn
    |> Conn.configure_session(drop: true)
    |> Conn.delete_session(:user_id)
  end

  defp validate_user(user) do
    user
    |> Ecto.Changeset.cast(%{validated?: true}, [:validated?])
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
  hash is persisted. `value` carries flow-specific data (e.g. the new address for
  an email change).
  """
  def gen_pin_for(user, type, value \\ nil) do
    pin = gen_pin()
    salt = :crypto.strong_rand_bytes(16)

    case Repo.one(from(m in LoginPin, where: m.user_id == ^user.id and m.type == ^type)) do
      nil -> Ecto.build_assoc(user, :login_pins)
      login_pin -> login_pin
    end
    |> LoginPin.changeset(%{
      type: type,
      value: value,
      created_at: NaiveDateTime.from_erl!(:calendar.universal_time()),
      pin: hash_pin(pin, salt),
      pin_salt: salt,
      pin_login_attempts: 0
    })
    |> Repo.insert_or_update!()

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
    |> LoginPin.changeset(%{created_at: nil})
    |> Repo.update!()
  end

  defp pin_expired?(%{created_at: nil}), do: true

  defp pin_expired?(%{created_at: date_time}) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), date_time, :second) > @pin_expire_time
  end

  @doc """
  Whether a login PIN is in flight for `email` (minted, and its `created_at`
  not yet cleared by consumption or lockout), i.e. the visitor should be
  offered the PIN-entry form instead of the sign-up page.
  """
  def login_pin_pending?(email) do
    Repo.exists?(
      from(m in LoginPin,
        join: u in assoc(m, :user),
        join: e in assoc(u, :emails),
        where: e.value == ^email and m.type == "login" and not is_nil(m.created_at)
      )
    )
  end

  @doc """
  Verifies a one-time PIN.

  Two ways in: pass a `%User{}` for the authenticated email-change and
  account-deletion flows (identity comes from the session), or pass the typed
  email for `"login"` (identity is carried by the signed cookie).

  Returns `{:ok, user}` for login/delete, `{:ok, value, user}` for the
  email-change flow (where `value` is the new address), `{:error, message}` on a
  wrong PIN, `{:expired, message}` once the PIN has timed out, or `:lockout`
  after too many wrong attempts.
  """
  def check_pin(%User{} = user, pin, type) do
    Repo.one(from(m in LoginPin, where: m.user_id == ^user.id and m.type == ^type))
    |> verify_pin(pin)
  end

  def check_pin(email, pin, "login") when is_binary(email) do
    Repo.one(
      from(m in LoginPin,
        join: u in assoc(m, :user),
        join: e in assoc(u, :emails),
        where: e.value == ^email and m.type == ^"login"
      )
    )
    |> verify_pin(pin)
  end

  defp verify_pin(nil, _pin) do
    {:error, Gettext.gettext(VutuvWeb.Gettext, "An error occured")}
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
  defp valid_pin?(%LoginPin{pin: stored, pin_salt: salt}, pin)
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

  defp pin_response(%LoginPin{value: nil, user_id: user_id}) do
    {:ok, Repo.get(User, user_id)}
  end

  defp pin_response(%LoginPin{value: value, user_id: user_id}) do
    {:ok, value, Repo.get(User, user_id)}
  end

  # ── User CRUD ──

  def count_users do
    Repo.one(from(u in User, select: count(u.id)))
  end

  @doc """
  The user behind a current profile slug, or nil. Only resolves the *active*
  slug (links rendered now), not retired ones — those stay a controller-plug
  concern (`VutuvWeb.Plug.ResolveSlug`).
  """
  def get_user_by_slug(slug) when is_binary(slug) do
    Repo.get_by(User, active_slug: slug)
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
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
