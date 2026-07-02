defmodule Vutuv.Social.PopularUsers do
  @moduledoc """
  Periodically cached "most followed members" pool.

  `Social.most_followed_users/1` used to run a GROUP BY over the whole
  `follows` table on every call — and it is called from the hottest paths:
  both mounts of every feed view (the "Who to follow" rail), the profile's
  recommendation fallback, and the `/listings/most_followed_users` page. The
  ranking moves slowly (it takes many follows to change a top spot) and the
  rails shuffle their slice anyway, so freshness within a few minutes is
  plenty.

  One GenServer owns the slow path: it recomputes the top 1000 every few
  minutes into a `read_concurrency` ETS table; readers take their prefix from
  the snapshot with no database round trip. When the table is missing or not
  yet seeded (application boot, tests — the refresh timer is off under
  `config :vutuv, :refresh_popular_users, false`), `top/2` returns `:miss`
  and `Social.most_followed_users/1` transparently falls back to the query,
  so behaviour is unchanged, only cheaper.
  """
  use GenServer

  @table __MODULE__
  @pool_size 1000
  @refresh_interval :timer.minutes(10)

  @doc "How many members the snapshot ranks (the largest servable limit)."
  def pool_size, do: @pool_size

  @doc """
  The cached top `limit` as `{:ok, users}`, or `:miss` when the snapshot
  cannot answer (not seeded yet, table absent, or `limit` beyond the pool).
  """
  def top(limit, table \\ @table)

  def top(limit, _table) when limit > @pool_size, do: :miss

  def top(limit, table) do
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
    :ets.insert(table, {:pool, Vutuv.Social.compute_most_followed(@pool_size)})
  end

  defp schedule(interval), do: Process.send_after(self(), :refresh, interval)

  defp enabled?, do: Application.get_env(:vutuv, :refresh_popular_users, true)
end
