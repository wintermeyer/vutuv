defmodule Vutuv.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Vutuv.RateLimiter

  setup do
    RateLimiter.reset()
    :ok
  end

  test "allows hits up to the limit, then blocks within the same window" do
    key = {:test, :allow}

    assert RateLimiter.hit(key, 3, 60_000) == :ok
    assert RateLimiter.hit(key, 3, 60_000) == :ok
    assert RateLimiter.hit(key, 3, 60_000) == :ok
    assert RateLimiter.hit(key, 3, 60_000) == {:error, :rate_limited}
  end

  test "separate keys keep separate counters" do
    assert RateLimiter.hit({:test, :b}, 1, 60_000) == :ok
    assert RateLimiter.hit({:test, :c}, 1, 60_000) == :ok
    assert RateLimiter.hit({:test, :b}, 1, 60_000) == {:error, :rate_limited}
  end
end
