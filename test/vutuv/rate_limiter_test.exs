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

  # The hot path goes straight at the table and only builds it from the
  # `ArgumentError` of a missing one, so the table's absence is no longer
  # checked before every hit — these pin what that fallback still owes.
  describe "missing table" do
    setup :bounce_limiter_on_exit

    test "hit/3 rebuilds the table and keeps counting" do
      assert :ets.delete(RateLimiter)
      assert :ets.whereis(RateLimiter) == :undefined

      assert RateLimiter.hit({:test, :lazy}, 2, 60_000) == :ok
      assert :ets.whereis(RateLimiter) != :undefined

      # The rebuilt table is a real counter, not a swallowed error.
      assert RateLimiter.hit({:test, :lazy}, 2, 60_000) == :ok
      assert RateLimiter.hit({:test, :lazy}, 2, 60_000) == {:error, :rate_limited}
    end

    test "peek/2 rebuilds the table and reads 0" do
      assert :ets.delete(RateLimiter)

      assert RateLimiter.peek({:test, :lazy_peek}, 60_000) == 0
      assert :ets.whereis(RateLimiter) != :undefined
    end
  end

  # Calibration: this goes red both ways the retry can stop being fail-fast —
  # a `rescue` that swallows the error, and a retry that is itself rescued.
  test "a badarg that is not a missing table raises instead of retrying" do
    # Arbitrarily long: the only requirement is that the window cannot roll
    # between the insert and the call, which would move the bucket to a fresh
    # one and hide the corrupt counter.
    window_ms = :timer.hours(100_000)
    key = {:test, :corrupt}
    window = div(System.system_time(:millisecond), window_ms)

    # Position 2 is the counter; a non-integer there is a genuine badarg that
    # rebuilding the table cannot fix.
    :ets.insert(RateLimiter, {{key, window}, :not_an_integer, 0})

    assert_raise ArgumentError, fn -> RateLimiter.hit(key, 3, window_ms) end
  end

  # The point of the whole exercise, pinned so it cannot be undone quietly.
  # Reinstating a probe changes no behaviour and breaks no other test — it just
  # costs an `:ets.whereis/1` on every rate-limited request again. Not
  # hypothetical: the `open_table/1` that #1757 generates for this module is
  # `EtsCache.ensure/2`, i.e. exactly that probe, and its `hit_remaining/3`
  # opens the table on every call. Rebasing onto it by taking its side here
  # would hand the cost back with the whole suite still green.
  #
  # So this reads the compiled function rather than its behaviour: on the hot
  # path `hit_remaining/3` may call nothing but the clock and `count_hit/2`,
  # which is where the `rescue` that heals a missing table lives. Anything else
  # — `ensure_table/0`, an `open_table/0`, `:ets.whereis/1` — is a probe back on
  # the hot path. If you are adding a legitimate call here, widen the list on
  # purpose; that is the point of it being narrow.
  test "hit_remaining/3 calls nothing that could probe for the table" do
    Code.ensure_loaded!(Vutuv.RateLimiter)
    {:beam_file, _, _, _, _, code} = :beam_disasm.file(:code.which(Vutuv.RateLimiter))

    {:function, _, _, _, instructions} =
      Enum.find(code, fn {:function, name, arity, _, _} ->
        {name, arity} == {:hit_remaining, 3}
      end)

    called =
      Enum.flat_map(instructions, fn
        {op, _, {:extfunc, m, f, a}} when op in [:call_ext, :call_ext_only] ->
          ["#{inspect(m)}.#{f}/#{a}"]

        {:call_ext_last, _, {:extfunc, m, f, a}, _} ->
          ["#{inspect(m)}.#{f}/#{a}"]

        {op, _, {_, f, a}} when op in [:call, :call_only] ->
          ["#{f}/#{a}"]

        {:call_last, _, {_, f, a}, _} ->
          ["#{f}/#{a}"]

        _ ->
          []
      end)

    assert Enum.sort(Enum.uniq(called)) == ["System.system_time/1", "count_hit/2"]
  end

  # A table rebuilt by the fallback is owned by the test process and dies with
  # it, leaving the supervised limiter without one. Bounce the child so it owns
  # a fresh table again before the next test runs.
  defp bounce_limiter_on_exit(_context) do
    on_exit(fn ->
      :ok = Supervisor.terminate_child(Vutuv.Supervisor, RateLimiter)
      {:ok, _pid} = Supervisor.restart_child(Vutuv.Supervisor, RateLimiter)
    end)

    :ok
  end
end
