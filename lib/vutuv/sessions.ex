defmodule Vutuv.Sessions do
  @moduledoc """
  Server-side records of where an account is signed in.

  Each browser login mints a `Vutuv.Sessions.UserSession` row: the SHA-256 of a
  random per-session token (the raw token rides in the signed cookie, only the
  hash is stored — like `Vutuv.ApiAuth.Token`), the device fingerprint captured
  at login (User-Agent, IP, best-effort coarse location), and timestamps. This
  is what powers:

    * the **owner's signed-in-devices list** with per-device remote logout and
      "log out all other devices" (issue #794), and
    * the **new-device / suspicious-login security email** (issue #786), which
      sits on the very same rows.

  Revocation is a per-request DB check, on purpose: `revoke/1` sets `revoked_at`
  and immediately kills the device's live sockets, and `VutuvWeb.Plug.Configure
  Session` drops the cookie on that device's next request. There is no cache to
  wait out.

  Each session has its **own** live-socket topic (`socket_id/1`,
  `users_socket:<session id>`) so one device can be disconnected without
  touching the others; `disconnect_user/1` fans a logout out across every one
  (plus the legacy user-wide topic, for sessions minted before this feature).
  """

  import Ecto.Query

  require Logger

  alias Vutuv.Accounts
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Repo
  alias Vutuv.Sessions.UserSession
  alias Vutuv.Token

  # last_seen_at is an audit trail, not a precise counter; bumping it at most
  # once a minute keeps the hot session row from being written on every request
  # (the same resolution Vutuv.ApiAuth uses for last_used_at).
  @last_seen_resolution_seconds 60

  # ── Minting (the login path) ──

  @doc """
  Starts a tracked session for `user` from `conn` (the device fingerprint comes
  from its headers). Returns `{raw_token, session}`: store `raw_token` in the
  signed cookie, hand `session` to `socket_id/1` for the per-session live topic.

  Detects whether the login is noteworthy (new device, concurrent session,
  suspicious location) and — unless `alert: false` — mails the owner a security
  notice off the request path (issue #786). The `alert: false` path is the
  lazy upgrade of a pre-feature legacy cookie, which must stay silent so a
  deploy does not blast every returning member with a "new device" mail.
  """
  def start_session(%Accounts.User{} = user, conn, opts \\ []) do
    {ua, ip} = fingerprint_from_conn(conn)
    location = Vutuv.Geo.locate(ip)

    reasons = if Keyword.get(opts, :alert, true), do: alert_reasons(user, ua, location), else: []

    raw_token = Token.random_token()
    now = DateTime.utc_now(:second)

    session =
      %UserSession{user_id: user.id, token_hash: hash_token(raw_token), last_seen_at: now}
      |> UserSession.changeset(%{user_agent: ua, ip_address: ip, approx_location: location})
      |> Repo.insert!()

    if email_worthy?(reasons), do: dispatch_alert(user, session, reasons)

    {raw_token, session}
  end

  # The User-Agent and source IP of the request behind a login. remote_ip is the
  # same source the rate limiter keys on (best-effort behind a proxy).
  defp fingerprint_from_conn(conn) do
    ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first()
    ip = conn.remote_ip && conn.remote_ip |> :inet.ntoa() |> to_string()
    {ua, ip}
  end

  # ── Per-request identification (the ConfigureSession plug) ──

  @doc """
  The active (not revoked) session for `raw_token`, or `nil` when the token is
  missing, unknown, or revoked. The owner preloaded, so the plug can apply the
  same suspension/deactivation gate it applies to a freshly loaded user.
  """
  def active_session(token) when is_binary(token) do
    Repo.one(
      from(s in UserSession,
        where: s.token_hash == ^hash_token(token) and is_nil(s.revoked_at),
        preload: [:user]
      )
    )
  end

  def active_session(_token), do: nil

  @doc """
  Bumps `last_seen_at` to now, but at most once per
  #{@last_seen_resolution_seconds}s, so the hot session row is not written on
  every request. Returns the (possibly unchanged) session.
  """
  def touch(%UserSession{} = session) do
    now = DateTime.utc_now(:second)

    if is_nil(session.last_seen_at) or
         DateTime.diff(now, session.last_seen_at) >= @last_seen_resolution_seconds do
      session |> Ecto.Changeset.change(last_seen_at: now) |> Repo.update!()
    else
      session
    end
  end

  # ── The owner's signed-in-devices list ──

  @doc "The user's active (not revoked) sessions, most-recently-active first."
  def list_active(%Accounts.User{} = user) do
    Repo.all(
      from(s in UserSession,
        where: s.user_id == ^user.id and is_nil(s.revoked_at),
        order_by: [desc: s.last_seen_at, desc: s.id]
      )
    )
  end

  @doc "Fetches one of the user's own sessions, or nil (also on a malformed id)."
  def get_session(%Accounts.User{} = user, id) do
    Vutuv.UUIDv7.with_cast(id, &Repo.get_by(UserSession, id: &1, user_id: user.id))
  end

  # ── The profile-completion onboarding window ──

  # How long after a fresh sign-in a member keeps seeing the profile-completion
  # checklist. Kept equal to the "new account" window in VutuvWeb.UserController
  # so a returning member gets the same brief nudge a brand-new one does, never a
  # permanent one.
  @onboarding_window_seconds 24 * 60 * 60

  # No session activity for over a year is the gap after which a returning member
  # is treated as freshly re-onboarding.
  @dormant_seconds 365 * 24 * 60 * 60

  @doc """
  Whether `user` is in a brief "fresh return" window worth re-surfacing the
  profile-completion checklist for (see `VutuvWeb.UserController`).

  True when the account has a session that started within the last
  #{div(@onboarding_window_seconds, 3600)}h **and** every session that started
  before that was last seen over a year ago (or there is none). That is exactly
  two members and no one else:

    * one returning after more than a year away (their old sessions are stale), and
    * a legacy account signing in for the first time since per-session tracking
      shipped — its lazily-upgraded session is its only one, with nothing behind it.

  A member who has merely stayed signed in is **not** fresh: their session
  started over #{div(@onboarding_window_seconds, 3600)}h ago. The older sessions
  are gated on `last_seen_at`, not `inserted_at`, on purpose: a long-lived
  session kept alive all year has a recent `last_seen_at`, so it reads as "active
  within the year", not as a year-old login.
  """
  def fresh_return?(%Accounts.User{} = user) do
    recent_cutoff =
      NaiveDateTime.add(NaiveDateTime.utc_now(), -@onboarding_window_seconds, :second)

    year_cutoff = DateTime.add(DateTime.utc_now(:second), -@dormant_seconds, :second)

    {recent, older} =
      Repo.all(
        from(s in UserSession,
          where: s.user_id == ^user.id,
          select: %{inserted_at: s.inserted_at, last_seen_at: s.last_seen_at}
        )
      )
      |> Enum.split_with(&(NaiveDateTime.compare(&1.inserted_at, recent_cutoff) == :gt))

    recent != [] and
      Enum.all?(older, fn s ->
        is_nil(s.last_seen_at) or DateTime.compare(s.last_seen_at, year_cutoff) == :lt
      end)
  end

  # ── Revocation ──

  @doc """
  Revokes one session and immediately disconnects its live sockets. The device
  falls back to the anonymous view on its next request. A no-op if already
  revoked. Returns the session.
  """
  def revoke(%UserSession{revoked_at: nil} = session) do
    session =
      session |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update!()

    disconnect(socket_id(session))
    session
  end

  def revoke(%UserSession{} = session), do: session

  @doc """
  Revokes every active session of `user` **except** the one with
  `keep_session_id` (the current device), disconnecting each. Pass `nil` to
  revoke all. Returns the number of sessions revoked.
  """
  def revoke_all_except(%Accounts.User{} = user, keep_session_id) do
    query =
      from(s in UserSession,
        where: s.user_id == ^user.id and is_nil(s.revoked_at),
        select: s.id
      )

    # `nil` means "revoke all" (keep nothing); otherwise spare the current row.
    query = if keep_session_id, do: where(query, [s], s.id != ^keep_session_id), else: query

    # One statement marks the rows and returns their ids (Postgres RETURNING),
    # so there is no separate load + in-memory reject.
    {count, revoked_ids} = Repo.update_all(query, set: [revoked_at: DateTime.utc_now(:second)])

    Enum.each(revoked_ids, &disconnect(socket_id_for(&1)))
    count
  end

  @doc """
  Disconnects every live socket of `user_id` across all their sessions, plus the
  legacy user-wide topic. Used when an account is suspended/deactivated/deleted
  so already-open tabs drop the logged-in chrome at once (it does **not** revoke
  the rows — deletion cascades them, suspension is re-checked on every request).
  """
  def disconnect_user(user_id) do
    Repo.all(from(s in UserSession, where: s.user_id == ^user_id, select: s.id))
    |> Enum.each(&disconnect(socket_id_for(&1)))

    # Sessions minted before this feature still ride the old user-wide topic.
    disconnect(legacy_socket_id(user_id))
  end

  # ── Live-socket topics ──

  @doc "The per-session live-socket topic put in the cookie's `live_socket_id`."
  def socket_id(%UserSession{id: id}), do: socket_id_for(id)

  defp socket_id_for(session_id), do: "users_socket:#{session_id}"

  # The pre-feature, shared-across-tabs topic (`users_socket:<user id>`), still
  # carried by cookies minted before per-session sockets existed.
  defp legacy_socket_id(user_id), do: "users_socket:#{user_id}"

  @doc """
  Broadcasts the live-socket disconnect for one topic. The single owner of the
  `"disconnect"` event so the topic format and event name live in one place;
  callers outside this context (the logout path) hand it a `live_socket_id`
  read straight from the cookie.
  """
  def disconnect(topic), do: VutuvWeb.Endpoint.broadcast(topic, "disconnect", %{})

  # ── Security-alert detection (issue #786) ──

  @doc """
  The list of noteworthy properties of this login, computed from the user's
  prior sessions: `:new_device`, `:concurrent`, `:suspicious_location` (any
  subset, in that order). Public so the detection is unit-testable in isolation
  from the cookie/live-socket plumbing.
  """
  def alert_reasons(%Accounts.User{} = user, ua, location) do
    # Only the three fields the predicates below read — not whole rows — so an
    # account with a long sign-in history pays a narrow scan, not a full-row
    # hydration of every session it has ever had.
    prior =
      Repo.all(
        from(s in UserSession,
          where: s.user_id == ^user.id,
          select: %{
            user_agent: s.user_agent,
            approx_location: s.approx_location,
            revoked_at: s.revoked_at
          }
        )
      )

    []
    |> maybe(new_device?(prior, ua), :new_device)
    |> maybe(concurrent?(prior), :concurrent)
    |> maybe(suspicious_location?(prior, location), :suspicious_location)
    |> Enum.reverse()
  end

  defp maybe(reasons, true, reason), do: [reason | reasons]
  defp maybe(reasons, false, _reason), do: reasons

  # A genuinely new device: the account has signed in before, but never from a
  # device that fingerprints to the same coarse summary. The very first login
  # ever is NOT new (there is nothing suspicious about your first sign-in, and
  # it would fire on every fresh registration).
  defp new_device?([], _ua), do: false

  defp new_device?(prior, ua) do
    fingerprint = device_summary(ua)
    Enum.all?(prior, &(device_summary(&1.user_agent) != fingerprint))
  end

  # Another session is already active for this account.
  defp concurrent?(prior), do: Enum.any?(prior, &is_nil(&1.revoked_at))

  # A login from a location that does not match any location the account has
  # been seen from. Dormant until a geo provider is configured (Vutuv.Geo): with
  # no known prior location there is nothing to be suspicious about.
  defp suspicious_location?(_prior, nil), do: false

  defp suspicious_location?(prior, location) do
    known = prior |> Enum.map(& &1.approx_location) |> Enum.reject(&is_nil/1)
    known != [] and Enum.all?(known, &(&1 != location))
  end

  # New device or suspicious location is high-signal and mails the owner. A
  # merely concurrent session is recorded and shown in the mail as context, but
  # does not on its own send one (a member with a phone and a laptop open at
  # once is normal — alerting on it every time is noise, not security).
  defp email_worthy?(reasons) do
    :new_device in reasons or :suspicious_location in reasons
  end

  defp dispatch_alert(user, session, reasons) do
    email = Accounts.first_email_value(user)
    if email, do: deliver_off_request_path(user, email, session, reasons)
    :ok
  end

  # Mailed off the request path in production so a slow SMTP send never delays
  # the login response; delivered inline in tests (`:async_email` false) so the
  # Swoosh test adapter's message reaches the asserting process. A failed send
  # is logged, never raised — a login must not fail because an alert could not
  # be mailed.
  defp deliver_off_request_path(user, email, session, reasons) do
    send = fn ->
      try do
        user
        |> Emailer.security_alert_email(email, session, reasons)
        |> Emailer.deliver()
      rescue
        error -> Logger.error("security alert email to #{email} failed: #{inspect(error)}")
      end
    end

    if Application.get_env(:vutuv, :async_email, true) do
      {:ok, _pid} = Task.Supervisor.start_child(Vutuv.TaskSupervisor, send)
    else
      send.()
    end

    :ok
  end

  # ── Device fingerprint formatting (shared by the list and the email) ──

  @doc """
  A short, human-readable summary of a User-Agent string ("Chrome on macOS",
  "Safari on iPhone"), the label the device list and the security email both
  show. Falls back to "Unknown device" for a missing or unrecognized UA — which
  is also why two such logins never look like a new device to each other.
  """
  def device_summary(nil), do: "Unknown device"

  def device_summary(ua) when is_binary(ua) do
    browser = browser_name(ua)
    os = os_name(ua)

    cond do
      browser && os -> "#{browser} on #{os}"
      browser -> browser
      os -> os
      true -> "Unknown device"
    end
  end

  @doc """
  Whether a User-Agent looks like a phone/tablet, picking the device-list glyph.
  Reuses the same OS classification `device_summary/1` relies on (plus the
  generic `Mobile` token), so the glyph never disagrees with the label.
  """
  def mobile?(ua) when is_binary(ua),
    do: os_name(ua) in ["iPhone", "iPad", "Android"] or ua =~ ~r/Mobile/i

  def mobile?(_ua), do: false

  # Order matters: Edge/Opera/Chrome all carry "Chrome", so the more specific
  # token has to win first.
  defp browser_name(ua) do
    cond do
      ua =~ ~r/Edg(e|A|iOS)?\//i -> "Edge"
      ua =~ ~r/OPR\/|Opera/i -> "Opera"
      ua =~ ~r/Firefox\//i -> "Firefox"
      ua =~ ~r/Chrome\/|CriOS\//i -> "Chrome"
      ua =~ ~r/Safari\//i -> "Safari"
      true -> nil
    end
  end

  defp os_name(ua) do
    cond do
      ua =~ ~r/iPhone/i -> "iPhone"
      ua =~ ~r/iPad/i -> "iPad"
      ua =~ ~r/Android/i -> "Android"
      ua =~ ~r/Windows/i -> "Windows"
      ua =~ ~r/Mac OS X|Macintosh/i -> "macOS"
      ua =~ ~r/CrOS/i -> "ChromeOS"
      ua =~ ~r/Linux/i -> "Linux"
      true -> nil
    end
  end

  # ── Token helpers ──

  # The token shape lives in Vutuv.Token (shared with the API tokens); kept here
  # as a thin pass-through only because a test recomputes a session's hash.
  @doc false
  def hash_token(plaintext), do: Token.hash_token(plaintext)
end
