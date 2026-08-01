defmodule Vutuv.Landing.Showcase do
  @moduledoc """
  Periodically cached snapshot of the landing page's examples.

  The logged-out landing page is the most requested page in the app and the one
  every crawler meets first, while `Vutuv.Landing`'s ranking query (plus the
  full post-card preloads on what wins) returns the same rows for every visitor
  and moves only as fast as somebody posts. So one GenServer owns the slow
  path — exactly the `Vutuv.Posts.TopPosters` deal — refreshing into a
  `read_concurrency` ETS table every few minutes, and readers take the snapshot
  with no database round trip.

  When the snapshot cannot answer — application boot, or tests, where the
  refresh timer is off under `config :vutuv, :refresh_landing_showcase, false`
  because its queries would use the SQL-sandbox connection from a process that
  does not own it — `read/0` returns `:miss` and `Vutuv.Landing` transparently
  falls back to the live query. Behaviour is unchanged, only cheaper.
  """
  use GenServer

  alias Vutuv.Landing

  @table __MODULE__
  @refresh_interval :timer.minutes(5)

  @doc """
  The cached `%{posts: …, pool: …}` — the wall's opening hand plus the pool its
  shuffle button draws from — or `:miss` while the snapshot holds nothing.
  """
  def read(table \\ @table) do
    case :ets.lookup(table, :showcase) do
      [{:showcase, showcase}] -> {:ok, showcase}
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

    # The seed is a 0ms refresh rather than an inline query: ranking the posts
    # and loading their preloads must not block the supervisor at boot. Until it lands,
    # readers miss and fall back to the direct query.
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

  defp snapshot(table), do: :ets.insert(table, {:showcase, Landing.compute()})

  defp schedule(interval), do: Process.send_after(self(), :refresh, interval)

  defp enabled?, do: Application.get_env(:vutuv, :refresh_landing_showcase, true)
end
