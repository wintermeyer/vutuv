defmodule Vutuv.Posts.TopPosters do
  @moduledoc """
  Periodically cached "who to follow" candidate pool.

  `Posts.top_recent_posters/2` ranks the window's posters by the hearts their
  in-window posts collected — a whole-window aggregate over posts and likes
  that the profile page used to run on every single mount (including every
  crawler's dead render), although the ranking is identical for every viewer
  and moves only as fast as posts and likes land. One GenServer owns the slow
  path, exactly the `Vutuv.Social.PopularUsers` deal: it recomputes the pool
  every few minutes into a `read_concurrency` ETS table, and readers take
  their prefix from the snapshot with no database round trip. When the
  snapshot cannot answer (application boot, tests — the refresh timer is off
  under `config :vutuv, :refresh_top_posters, false` — or an unexpected
  window/limit), `top/2` returns `:miss` and `Posts.top_recent_posters/2`
  transparently falls back to the live query, so behaviour is unchanged, only
  cheaper. The per-viewer exclusions stay per-request in the profile.
  """
  use GenServer

  @table __MODULE__
  # The one posting window the profile asks for; any other window is a :miss.
  @window_days 28
  @pool_size 100
  @refresh_interval :timer.minutes(10)

  @doc "The snapshot's posting window in days (the profile rail's window)."
  def window_days, do: @window_days

  @doc "How many posters the snapshot ranks (the largest servable limit)."
  def pool_size, do: @pool_size

  @doc """
  The cached top `limit` posters of the `days` window as `{:ok, users}`, or
  `:miss` when the snapshot cannot answer (a different window, not seeded
  yet, table absent, or `limit` beyond the pool).
  """
  def top(days, limit, table \\ @table)

  def top(days, limit, _table) when days != @window_days or limit > @pool_size, do: :miss

  def top(_days, limit, table) do
    case :ets.lookup(table, :pool) do
      [{:pool, users}] -> {:ok, Enum.take(users, limit)}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Recompute the snapshot now (synchronous; used by tests)."
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh)

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    # `name: nil` (isolated test instances) starts the process unregistered.
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    table =
      :ets.new(Keyword.get(opts, :table, @table), [
        :named_table,
        :protected,
        read_concurrency: true
      ])

    interval = Keyword.get(opts, :refresh_interval, @refresh_interval)

    # The seed is a 0ms refresh rather than an inline query: the ranking scan
    # must not block the supervisor at boot. Until it lands, readers miss and
    # fall back to the direct query — exactly the pre-cache behaviour.
    if Keyword.get(opts, :refresh?, enabled?()), do: schedule(0)

    {:ok, %{table: table, interval: interval}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    snapshot(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    snapshot(state.table)
    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp snapshot(table) do
    :ets.insert(
      table,
      {:pool, Vutuv.Posts.compute_top_recent_posters(@window_days, @pool_size)}
    )
  end

  defp schedule(interval), do: Process.send_after(self(), :refresh, interval)

  defp enabled?, do: Application.get_env(:vutuv, :refresh_top_posters, true)
end
