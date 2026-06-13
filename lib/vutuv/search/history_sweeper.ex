defmodule Vutuv.Search.HistorySweeper do
  @moduledoc """
  Periodically prunes the search-history tables (`search_queries`,
  `search_query_results`, `search_query_requesters`) to the retention window in
  `Vutuv.Search.prune_history/1`. These tables are written on every settled
  search but feed no user-facing feature, so without this they grow without
  bound and keep who-searched-what forever.

  Runs daily. The first sweep is one interval after boot (not at boot), so it
  never races startup nor the SQL Sandbox; the existing backlog is reclaimed on
  that first run. Disabled in tests (`config :vutuv, :prune_search_history,
  false`): the sweep would use the Sandbox connection from a process that does
  not own it. Tests call `Vutuv.Search.prune_history/1` directly instead.
  """

  use GenServer

  require Logger

  @interval :timer.hours(24)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    case Vutuv.Search.prune_history() do
      %{search_queries: 0, search_query_requesters: 0} ->
        :ok

      %{search_queries: queries, search_query_requesters: requesters} ->
        Logger.info("Pruned search history: #{queries} queries, #{requesters} requester rows")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
