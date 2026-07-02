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
      keys = [{event, :ip, ip(conn)} | identity_keys(event, extra)]

      results = Enum.map(keys, fn key -> RateLimiter.hit(key, lim, win) end)

      if Enum.all?(results, &(&1 == :ok)), do: :ok, else: :rate_limited
    else
      :ok
    end
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
  defp identity_keys(event, extra), do: [{event, :id, normalize(extra)}]

  defp normalize(value) when is_binary(value), do: String.downcase(value)
  defp normalize(value), do: value

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
