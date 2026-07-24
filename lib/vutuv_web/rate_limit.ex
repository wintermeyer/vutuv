defmodule VutuvWeb.RateLimit do
  @moduledoc """
  Per-IP / per-email throttling for the PIN auth steps (issue #759 C.3), layered
  on top of the per-PIN attempt lockout. It is disabled in the test environment
  by default so the suite's many logins do not exhaust a shared counter; the
  dedicated rate-limit test flips it on.

  The per-IP key reads `conn.remote_ip`, which the endpoint's `RemoteIp` plug
  resolves to the real client address from `X-Forwarded-For` behind the nginx
  proxy. Before that fix every visitor collapsed onto the single loopback IP, so
  the per-IP budget was one global bucket and real members were locked out of
  login (issues #799, #837).
  """

  alias Vutuv.RateLimiter

  # 50 requests per 3 hours, per real client IP and per email. Generous on
  # purpose: this guards against abuse/enumeration, not honest use, and mobile
  # carriers put many subscribers behind one shared (CGNAT) public IP, so a tight
  # per-IP budget would lock innocent members out.
  @default_limit 50
  @default_window_ms :timer.hours(3)

  # Resending a PIN re-mints it and resets the per-PIN attempt counter, so an
  # unbounded resend turns the 3-strikes lockout into an open brute-force door.
  # It therefore gets its own deliberately slow budget, independent of the shared
  # per-request config: 5 resends per hour, per IP and per email.
  @resend_limit 5
  @resend_window_ms :timer.minutes(60)

  # The LinkedIn import decompresses an upload and writes a batch of rows, so it
  # gets its own modest budget (10 per hour, per IP and per member) on top of the
  # zip-bomb caps in Vutuv.Imports.LinkedIn. Overridable via config for the test.
  @import_limit 10
  @import_window_ms :timer.hours(1)

  @doc """
  Returns `:ok` when the request is within the limit for `event`, or
  `:rate_limited` once the per-IP or per-identity counter is exceeded. `extra` is
  an optional identity (typically the email) throttled independently of the IP,
  so one abusive client cannot lock out everyone and vice versa.

  `opts` may override `:limit` and `:window_ms` for events that need their own
  budget rather than the shared config one (see `check_login_resend/2`).
  """
  def check(conn, event, extra \\ nil, opts \\ []) do
    if enabled?() do
      lim = Keyword.get(opts, :limit, limit())
      win = Keyword.get(opts, :window_ms, window_ms())

      # Hit the per-IP bucket FIRST and stop the moment it is exhausted, before
      # touching (and thus creating) any per-identity bucket. This bounds the
      # number of identity buckets one IP can plant to its own per-window budget;
      # without it a rate-limited client kept writing a fresh identity bucket per
      # distinct email even after its IP budget was spent (F13). `and` short-
      # circuits, so `identities_ok?/4` never runs once the IP key is over.
      if RateLimiter.hit({event, :ip, ip(conn)}, lim, win) == :ok and
           identities_ok?(event, extra, lim, win) do
        :ok
      else
        :rate_limited
      end
    else
      :ok
    end
  end

  defp identities_ok?(event, extra, lim, win) do
    event
    |> identity_keys(extra)
    |> Enum.all?(fn key -> RateLimiter.hit(key, lim, win) == :ok end)
  end

  @doc """
  Throttles "resend my PIN" requests on their own slow budget (5 per hour, per
  IP and per email), so a fresh PIN cannot be minted faster than that no matter
  how the shared request limit is tuned.
  """
  def check_login_resend(conn, email) do
    check(conn, :login_resend, email, limit: @resend_limit, window_ms: @resend_window_ms)
  end

  @doc """
  Throttles a member's LinkedIn imports (10 per hour, per IP and per member id),
  so a single account cannot hammer the upload/parse/apply path. The budget is
  overridable via `config :vutuv, :linkedin_import_rate_limit, {limit, window_ms}`.
  """
  def check_linkedin_import(conn, user) do
    {limit, window_ms} =
      Application.get_env(:vutuv, :linkedin_import_rate_limit, {@import_limit, @import_window_ms})

    check(conn, :linkedin_import, user.id, limit: limit, window_ms: window_ms)
  end

  defp identity_keys(_event, nil), do: []
  defp identity_keys(event, extra), do: [{event, :id, hash_identity(extra)}]

  # Longest byte prefix of an identity value that is ever downcased/hashed. Real
  # identities are tiny (an email is <= 254 chars, a UUID id 36 bytes), so this
  # never truncates a legitimate value into a collision; it only caps the CPU an
  # attacker's oversized `session[email]` (up to Plug's body limit) can spend
  # before we discard the excess.
  @max_identity_bytes 1024

  # The `extra` for the email-keyed events is the RAW, length-unvalidated email
  # from unauthenticated public endpoints (POST /login etc.). Using it verbatim
  # as part of an ETS bucket key let an attacker plant a multi-MB row per distinct
  # value for the whole window (unbounded-growth DoS, F11), and — per the project
  # hashing rule — a bare hash of a low-entropy email is enumerable from an
  # in-memory table read. So collapse every identity to a FIXED-SIZE, keyed HMAC:
  # cap the length first (bounds CPU), downcase (case-insensitive bucketing), then
  # HMAC with a server-secret pepper (32-byte digest, and a table read alone can't
  # recover which emails hit the limiter). Applied uniformly to the `linkedin_import`
  # user id too — already fixed size, so hashing it is harmless and keeps one path.
  defp hash_identity(value) do
    normalized =
      value
      |> to_string()
      |> cap_length()
      |> String.downcase()

    :crypto.mac(:hmac, :sha256, pepper(), normalized)
  end

  defp cap_length(binary) when byte_size(binary) <= @max_identity_bytes, do: binary
  defp cap_length(binary), do: binary_part(binary, 0, @max_identity_bytes)

  # Dedicated pepper derived from `secret_key_base` with its OWN domain-separation
  # string (so it never equals the raw secret nor the login-PIN pepper), held
  # outside any persisted store — mirrors `Vutuv.Accounts`' login-PIN pepper.
  defp pepper do
    :crypto.hash(:sha256, "vutuv/rate_limit/pepper/v1" <> secret_key_base())
  end

  defp secret_key_base do
    Application.fetch_env!(:vutuv, VutuvWeb.Endpoint)[:secret_key_base]
  end

  # The real client address (resolved by the endpoint's RemoteIp plug from
  # X-Forwarded-For), not the loopback proxy hop.
  defp ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp config, do: Application.get_env(:vutuv, :rate_limit, [])
  defp enabled?, do: Keyword.get(config(), :enabled, true)
  defp limit, do: Keyword.get(config(), :limit, @default_limit)
  defp window_ms, do: Keyword.get(config(), :window_ms, @default_window_ms)
end
