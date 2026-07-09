defmodule Vutuv.CodeStats.Fetcher do
  @moduledoc """
  The background fetch coordinator of the code-forge statistics
  (`Vutuv.CodeStats`): fire-and-forget with a **single-flight guarantee** —
  N concurrent requests for the same account (a popular profile at snapshot
  expiry, or create + first page view racing) start exactly one supervised
  fetch task.

  Unlike `Vutuv.SocialFeed.Cache` there is no ETS table and no waiter list:
  the DB row is the cache (`code_stats` + `code_stats_fetched_at`), and open
  pages learn of a fresh snapshot over PubSub (`Vutuv.CodeStats.record_result/3`
  broadcasts on the owner's topic). Between-fetch throttling also needs no
  cache entry — a success stamps `code_stats_fetched_at` (fresh for 7 days),
  a failure stamps `fetch_retry_at`/`fetch_disabled_at`, and
  `CodeStats.refresh_if_stale/1` refuses to re-request either.

  `name:` is injectable so tests run isolated instances; the app-wide
  instance always starts (it does no work until something requests a fetch,
  and the `:fetch_code_stats` flag gates that in tests).
  """

  use GenServer

  require Logger

  alias Vutuv.CodeStats

  @doc "Requests one background fetch for this account; duplicates coalesce."
  def request(provider, handle, server \\ __MODULE__) do
    GenServer.cast(server, {:fetch, {provider, handle}})
  end

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    # `name: nil` (isolated test instances) starts the process unregistered.
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(_opts) do
    # inflight: the {provider, handle} keys being fetched right now;
    # refs: task ref => key, to route the task's reply and DOWN.
    {:ok, %{inflight: MapSet.new(), refs: %{}}}
  end

  @impl true
  def handle_cast({:fetch, key}, state) do
    if MapSet.member?(state.inflight, key) do
      {:noreply, state}
    else
      {provider, handle} = key

      task =
        Task.Supervisor.async_nolink(Vutuv.TaskSupervisor, fn ->
          CodeStats.fetch_stats(provider, handle)
        end)

      {:noreply,
       %{
         state
         | inflight: MapSet.put(state.inflight, key),
           refs: Map.put(state.refs, task.ref, key)
       }}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.refs, ref) do
    Process.demonitor(ref, [:flush])
    finish(ref, result, state)
  end

  # The fetch task crashed before replying (fetch_stats rescues, so this is
  # unexpected); count it as a transient failure so the forge gets its backoff.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.refs, ref) do
    finish(ref, {:error, :transient}, state)
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp finish(ref, result, state) do
    {key, refs} = Map.pop(state.refs, ref)
    record(key, result)
    {:noreply, %{state | inflight: MapSet.delete(state.inflight, key), refs: refs}}
  end

  # The snapshot/backoff bookkeeping must never take the fetcher down with
  # it; on a DB hiccup the next stale profile view simply asks again.
  defp record({provider, handle}, result) do
    CodeStats.record_result(provider, handle, result)
  rescue
    error ->
      Logger.warning(
        "code stats for #{inspect({provider, handle})} not recorded: #{inspect(error)}"
      )
  end
end
