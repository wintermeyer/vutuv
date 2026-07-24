defmodule VutuvWeb.RateLimitTest do
  use ExUnit.Case, async: false

  alias Vutuv.RateLimiter
  alias VutuvWeb.RateLimit

  setup do
    RateLimiter.reset()
    previous = Application.get_env(:vutuv, :rate_limit)
    on_exit(fn -> Application.put_env(:vutuv, :rate_limit, previous) end)
    :ok
  end

  defp conn(ip), do: %Plug.Conn{remote_ip: ip}

  # Largest serialized size of any bucket key currently in the limiter table. The
  # bucket is `{key, window}`; we measure just the caller `key` (the tuple the
  # RateLimit module builds), which is what an attacker's input would inflate.
  defp largest_bucket_key_bytes do
    RateLimiter
    |> :ets.tab2list()
    |> Enum.map(fn {{key, _window}, _count, _window_end} ->
      byte_size(:erlang.term_to_binary(key))
    end)
    |> Enum.max()
  end

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

  test "defaults to 50 requests per 3 hours when no limit/window is configured" do
    # No :limit/:window_ms override, so the module's @default_limit /
    # @default_window_ms apply (issue #837: 50 per 3h, per real client IP).
    Application.put_env(:vutuv, :rate_limit, enabled: true)
    c = conn({10, 0, 0, 50})

    for _ <- 1..50, do: assert(RateLimit.check(c, :login_email) == :ok)
    assert RateLimit.check(c, :login_email) == :rate_limited
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

  # F11: the raw email `extra` from the unauthenticated POST /login is length-
  # unvalidated, so used verbatim it becomes a multi-MB ETS bucket key retained
  # for the whole window. The keyed HMAC makes the identity component fixed-size.
  test "the per-identity bucket key stays fixed-size no matter how large the input" do
    Application.put_env(:vutuv, :rate_limit, enabled: true, limit: 5, window_ms: 60_000)

    giant = String.duplicate("x", 100_000)
    assert RateLimit.check(conn({10, 0, 0, 21}), :login_email, giant) == :ok

    # Every stored bucket key is small (a 32-byte digest + a couple of atoms),
    # not a ~100 KB copy of the attacker's input.
    assert largest_bucket_key_bytes() < 1_000
  end

  # F13: once the per-IP budget is spent, the limiter must refuse before touching
  # the per-identity key, so an abusive client cannot keep planting a fresh
  # identity bucket per distinct email after its IP counter is already exceeded.
  test "an IP-limited client cannot plant a new identity bucket (short-circuit)" do
    Application.put_env(:vutuv, :rate_limit, enabled: true, limit: 2, window_ms: 60_000)
    c = conn({10, 0, 0, 30})

    # Spend the per-IP budget of 2 on two distinct emails (each opens one identity
    # bucket while the IP is still within budget).
    assert RateLimit.check(c, :login_email, "one@x.com") == :ok
    assert RateLimit.check(c, :login_email, "two@x.com") == :ok

    buckets_before = :ets.info(RateLimiter, :size)

    # The IP is now exhausted, so a third request with a brand-new email must be
    # throttled WITHOUT ever creating that email's identity bucket.
    assert RateLimit.check(c, :login_email, "three@x.com") == :rate_limited

    assert :ets.info(RateLimiter, :size) == buckets_before
  end

  # Hashing must not lose the case-insensitive bucketing the raw downcase gave us.
  test "identity bucketing stays case-insensitive after hashing" do
    Application.put_env(:vutuv, :rate_limit, enabled: true, limit: 2, window_ms: 60_000)

    # The same address in three cases, from three different IPs, must share one
    # identity bucket, so the third (over the identity limit of 2) is throttled.
    assert RateLimit.check(conn({10, 0, 0, 41}), :login_email, "Foo@Example.com") == :ok
    assert RateLimit.check(conn({10, 0, 0, 42}), :login_email, "foo@example.com") == :ok
    assert RateLimit.check(conn({10, 0, 0, 43}), :login_email, "FOO@EXAMPLE.COM") == :rate_limited
  end
end
