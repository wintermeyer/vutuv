defmodule VutuvWeb.RateLimit do
  @moduledoc """
  Per-IP / per-email throttling for the PIN auth steps (issue #759 C.3), layered
  on top of the per-PIN attempt lockout. It is disabled in the test environment
  by default so the suite's many logins do not exhaust a shared counter; the
  dedicated rate-limit test flips it on.
  """

  alias Vutuv.RateLimiter

  @default_limit 5
  @default_window_ms :timer.minutes(10)

  # Resending a PIN re-mints it and resets the per-PIN attempt counter, so an
  # unbounded resend turns the 3-strikes lockout into an open brute-force door.
  # It therefore gets its own deliberately slow budget, independent of the shared
  # per-request config: 5 resends per hour, per IP and per email.
  @resend_limit 5
  @resend_window_ms :timer.minutes(60)

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

  defp identity_keys(_event, nil), do: []
  defp identity_keys(event, extra), do: [{event, :id, normalize(extra)}]

  defp normalize(value) when is_binary(value), do: String.downcase(value)
  defp normalize(value), do: value

  defp ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp config, do: Application.get_env(:vutuv, :rate_limit, [])
  defp enabled?, do: Keyword.get(config(), :enabled, true)
  defp limit, do: Keyword.get(config(), :limit, @default_limit)
  defp window_ms, do: Keyword.get(config(), :window_ms, @default_window_ms)
end
