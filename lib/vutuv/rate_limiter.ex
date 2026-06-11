defmodule Vutuv.RateLimiter do
  @moduledoc """
  A small in-memory fixed-window rate limiter backed by ETS.

  It throttles the PIN flows' email-entry and PIN-entry steps per IP and per
  email (issue #759 C.3), on top of the per-PIN 3-attempt lockout. Each counter
  lives in one shared ETS table keyed by `{caller_key, window}`, where the window
  index rolls over every `window_ms`; a fresh window starts a fresh count. A
  periodic sweep drops buckets whose window has passed so the table stays bounded.

  This is a process-local limiter (one node). It is good enough for the abuse and
  enumeration mitigation the issue asks for; it is not a distributed quota.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval :timer.minutes(5)

  # ── Public API ──

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records one hit for `key` and returns `:ok` while at or under `limit` within
  the current `window_ms` window, or `{:error, :rate_limited}` once the limit is
  exceeded. Creating the table lazily means callers work even if the limiter
  process has not been started (e.g. some unit tests).
  """
  def hit(key, limit, window_ms) do
    case hit_remaining(key, limit, window_ms) do
      {:ok, _remaining} -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  @doc """
  Like `hit/3`, but returns `{:ok, remaining}` so callers can expose the
  budget (the API's `X-RateLimit-Remaining` header).
  """
  def hit_remaining(key, limit, window_ms)
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    ensure_table()
    now = System.system_time(:millisecond)
    window = div(now, window_ms)
    window_end = (window + 1) * window_ms
    bucket = {key, window}

    count = :ets.update_counter(@table, bucket, {2, 1}, {bucket, 0, window_end})

    if count <= limit, do: {:ok, limit - count}, else: {:error, :rate_limited}
  end

  @doc false
  # Test helper: forget every recorded hit.
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  # ── GenServer ──

  @impl true
  def init(_opts) do
    ensure_table()
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  # ── Internals ──

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          # Lost a race with another process creating the table; that is fine.
          ArgumentError -> @table
        end

      _tid ->
        @table
    end
  end

  defp sweep do
    now = System.system_time(:millisecond)
    # Drop every bucket whose window has already ended.
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end
end
