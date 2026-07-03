defmodule Vutuv.SocialFeed.Cache do
  @moduledoc """
  The per-account cache and fetch coordinator for the inline social feeds
  (`Vutuv.SocialFeed`).

  One GenServer owns a `read_concurrency` ETS table of
  `{{provider, handle}, result, expires_at}` rows (result is `{:ok, %Feed{}}`
  or `{:error, reason}`); page processes read it directly through `lookup/2`
  and never block on the network.

  Every miss funnels through the GenServer, which is what makes the
  **single-flight guarantee** hold: a miss either starts exactly one
  supervised fetch task for that account or joins the waiter list of the one
  already in flight — N concurrent visitors of a popular profile at cache
  expiry produce exactly one outbound fetch, and every waiter gets the one
  result as a `{:social_feed_posts, provider, handle, result}` message.
  Failures are held for exactly the account's backoff window
  (`Vutuv.SocialFeed.record_result/3` decides), so a struggling server is not
  re-asked before its `fetch_retry_at`.

  Like `Vutuv.Social.PopularUsers`, `name:`/`table:`/TTL opts are injectable
  so tests run isolated instances; the app-wide instance always starts (it
  does no work until a page requests a fetch, and the per-provider feature
  flags gate that in tests).
  """
  use GenServer

  require Logger

  alias Vutuv.SocialFeed
  alias Vutuv.SocialFeed.Feed

  @table __MODULE__
  @posts_ttl :timer.minutes(15)
  # A deactivated account's ETS tombstone; the durable "never again" lives on
  # the account row, this only spares the GenServer repeat visits.
  @disabled_ttl :timer.hours(48)
  @sweep_interval :timer.minutes(30)

  @doc """
  The cached result for a `{provider, handle}` key: `{:ok, %Feed{}}`,
  `{:error, reason}`, or `:miss` (absent, expired, or the table does not exist
  yet). A caller-side ETS read; expired rows are left for the sweep.
  """
  def lookup({_provider, _handle} = key, table \\ @table) do
    case :ets.lookup(table, key) do
      [{^key, result, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: result, else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Asks for an account's posts; the result arrives at `pid` as a
  `{:social_feed_posts, provider, handle, result}` message — immediately when
  cached, otherwise after the (single-flight) fetch.
  """
  def request(provider, handle, pid, server \\ __MODULE__) do
    GenServer.cast(server, {:fetch, {provider, handle}, pid})
  end

  @doc "Drops every cached entry (tests)."
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

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

    state = %{
      table: table,
      posts_ttl: Keyword.get(opts, :posts_ttl, @posts_ttl),
      sweep_interval: Keyword.get(opts, :sweep_interval, @sweep_interval),
      # {provider, handle} => [waiter pids] — one key per fetch in flight.
      inflight: %{},
      # task ref => {provider, handle}, to route the task's reply and DOWN.
      refs: %{}
    }

    schedule_sweep(state.sweep_interval)
    {:ok, state}
  end

  @impl true
  def handle_cast({:fetch, key, pid}, state) do
    case lookup(key, state.table) do
      :miss ->
        {:noreply, start_or_join(key, pid, state)}

      result ->
        # Filled since the caller's own lookup missed (or it never looked):
        # answer straight from the cache.
        notify(pid, key, result)
        {:noreply, state}
    end
  end

  # The single-flight core: a miss either joins the waiter list of the fetch
  # already running for this account — never a second fetch — or starts the
  # one supervised fetch task.
  defp start_or_join(key, pid, state) do
    if Map.has_key?(state.inflight, key) do
      put_in(state.inflight[key], [pid | state.inflight[key]])
    else
      {provider, handle} = key

      task =
        Task.Supervisor.async_nolink(Vutuv.TaskSupervisor, fn ->
          SocialFeed.fetch_posts(provider, handle)
        end)

      %{
        state
        | inflight: Map.put(state.inflight, key, [pid]),
          refs: Map.put(state.refs, task.ref, key)
      }
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.refs, ref) do
    Process.demonitor(ref, [:flush])
    finish(ref, normalize(result), state)
  end

  # The fetch task crashed before replying (fetch_posts rescues, so this is
  # unexpected); count it as a transient failure so waiters never hang and the
  # server still gets its backoff.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.refs, ref) do
    finish(ref, {:error, :transient}, state)
  end

  def handle_info(:sweep, state) do
    # `=<` mirrors lookup/2's strict `now < expires_at` freshness check, so the
    # sweep drops exactly the rows lookup already refuses.
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(state.table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep(state.sweep_interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp finish(ref, result, state) do
    {key, refs} = Map.pop(state.refs, ref)
    {waiters, inflight} = Map.pop(state.inflight, key, [])

    ttl =
      case record_result(key, result) do
        :reset -> state.posts_ttl
        {:retry_in_minutes, minutes} -> :timer.minutes(minutes)
        :disabled -> @disabled_ttl
      end

    :ets.insert(state.table, {key, result, System.monotonic_time(:millisecond) + ttl})

    # Waiters that navigated away are dead pids — send/2 to those is a no-op.
    for pid <- waiters, do: notify(pid, key, result)

    {:noreply, %{state | refs: refs, inflight: inflight}}
  end

  defp notify(pid, {provider, handle}, result),
    do: send(pid, {:social_feed_posts, provider, handle, result})

  # The backoff bookkeeping must never take the cache down with it; on a DB
  # hiccup fall back to the first rung so nothing is hammered meanwhile.
  defp record_result({provider, handle}, result) do
    SocialFeed.record_result(provider, handle, result)
  rescue
    error ->
      Logger.warning(
        "social feed fetch state for #{inspect({provider, handle})} not recorded: #{inspect(error)}"
      )

      case result do
        {:ok, _} -> :reset
        _ -> {:retry_in_minutes, 15}
      end
  end

  defp normalize({:ok, %Feed{}} = ok), do: ok
  defp normalize({:error, _reason} = error), do: error
  defp normalize(_other), do: {:error, :transient}

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)
end
