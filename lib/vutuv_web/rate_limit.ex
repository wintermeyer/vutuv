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

  @doc """
  Returns `:ok` when the request is within the limit for `event`, or
  `:rate_limited` once the per-IP or per-identity counter is exceeded. `extra` is
  an optional identity (typically the email) throttled independently of the IP,
  so one abusive client cannot lock out everyone and vice versa.
  """
  def check(conn, event, extra \\ nil) do
    if enabled?() do
      keys = [{event, :ip, ip(conn)} | identity_keys(event, extra)]

      results = Enum.map(keys, fn key -> RateLimiter.hit(key, limit(), window_ms()) end)

      if Enum.all?(results, &(&1 == :ok)), do: :ok, else: :rate_limited
    else
      :ok
    end
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
