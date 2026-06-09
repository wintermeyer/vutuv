defmodule VutuvWeb.RateLimitTest do
  use ExUnit.Case, async: false

  alias VutuvWeb.RateLimit

  setup do
    Vutuv.RateLimiter.reset()
    previous = Application.get_env(:vutuv, :rate_limit)
    on_exit(fn -> Application.put_env(:vutuv, :rate_limit, previous) end)
    :ok
  end

  defp conn(ip), do: %Plug.Conn{remote_ip: ip}

  test "is a no-op when disabled (the test-env default)" do
    Application.put_env(:vutuv, :rate_limit, enabled: false)

    for _ <- 1..50 do
      assert RateLimit.check(conn({127, 0, 0, 1}), :evt) == :ok
    end
  end

  test "throttles per IP once enabled" do
    Application.put_env(:vutuv, :rate_limit, enabled: true, limit: 3, window_ms: 60_000)
    c = conn({10, 0, 0, 1})

    assert RateLimit.check(c, :evt) == :ok
    assert RateLimit.check(c, :evt) == :ok
    assert RateLimit.check(c, :evt) == :ok
    assert RateLimit.check(c, :evt) == :rate_limited
  end

  test "throttles per identity even across different IPs" do
    Application.put_env(:vutuv, :rate_limit, enabled: true, limit: 2, window_ms: 60_000)

    assert RateLimit.check(conn({10, 0, 0, 2}), :evt, "a@b.com") == :ok
    assert RateLimit.check(conn({10, 0, 0, 3}), :evt, "a@b.com") == :ok
    assert RateLimit.check(conn({10, 0, 0, 4}), :evt, "a@b.com") == :rate_limited
  end

  test "an explicit per-call limit overrides the configured one" do
    Application.put_env(:vutuv, :rate_limit, enabled: true, limit: 100, window_ms: 60_000)
    c = conn({10, 0, 0, 5})

    assert RateLimit.check(c, :evt, nil, limit: 1, window_ms: 60_000) == :ok
    assert RateLimit.check(c, :evt, nil, limit: 1, window_ms: 60_000) == :rate_limited
  end

  # Resending a PIN re-mints it and resets the per-PIN attempt counter, so it is
  # the real brute-force lever. It gets its own deliberately slow budget (5 per
  # hour, per IP and per email) regardless of the shared limit/window config.
  test "login resend is capped at 5 per hour" do
    Application.put_env(:vutuv, :rate_limit, enabled: true)
    c = conn({10, 0, 0, 6})

    for _ <- 1..5, do: assert(RateLimit.check_login_resend(c, "x@y.com") == :ok)
    assert RateLimit.check_login_resend(c, "x@y.com") == :rate_limited
  end
end
