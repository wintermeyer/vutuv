defmodule Vutuv.Mastodon.FeedCache do
  @moduledoc """
  The per-handle cache and fetch coordinator for the inline Mastodon feed.

  One GenServer owns a `read_concurrency` ETS table of
  `{handle, result, expires_at}` rows (result is `{:ok, posts}` or
  `{:error, reason}`); page processes read it directly through `lookup/2` and
  never block on the network.

  Every miss funnels through the GenServer, which is what makes the
  **single-flight guarantee** hold: a miss either starts exactly one
  supervised fetch task for that handle or joins the waiter list of the one
  already in flight — N concurrent visitors of a popular profile at cache
  expiry produce exactly one outbound fetch, and every waiter gets the one
  result as a `{:mastodon_posts, handle, result}` message. Failures are held
  for exactly the account's backoff window (`Vutuv.Mastodon.record_result/2`
  decides), so a struggling instance is not re-asked before its
  `fetch_retry_at`.

  Like `Vutuv.Social.PopularUsers`, `name:`/`table:`/TTL opts are injectable
  so tests run isolated instances; the app-wide instance always starts (it
  does no work until a page requests a fetch, and `Vutuv.Mastodon.enabled?/0`
  gates that in tests).
  """
  use GenServer

  require Logger

  alias Vutuv.Mastodon
  alias Vutuv.Mastodon.Feed

  @table __MODULE__
  @posts_ttl :timer.minutes(15)
  # A deactivated handle's ETS tombstone; the durable "never again" lives on
  # the account row, this only spares the GenServer repeat visits.
  @disabled_ttl :timer.hours(48)
  @sweep_interval :timer.minutes(30)

  @doc """
  The cached result for a handle: `{:ok, posts}`, `{:error, reason}`, or
  `:miss` (absent, expired, or the table does not exist yet). A caller-side
  ETS read; expired rows are left for the sweep.
  """
  def lookup(handle, table \\ @table) do
    case :ets.lookup(table, handle) do
      [{^handle, result, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: result, else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Asks for a handle's posts; the result arrives at `pid` as a
  `{:mastodon_posts, handle, result}` message — immediately when cached,
  otherwise after the (single-flight) fetch.
  """
  def request(handle, pid, server \\ __MODULE__) do
    GenServer.cast(server, {:fetch, handle, pid})
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
      # handle => [waiter pids] — one key per fetch in flight.
      inflight: %{},
      # task ref => handle, to route the task's reply and DOWN.
      refs: %{}
    }

    schedule_sweep(state.sweep_interval)
    {:ok, state}
  end

  @impl true
  def handle_cast({:fetch, handle, pid}, state) do
    case lookup(handle, state.table) do
      :miss ->
        {:noreply, start_or_join(handle, pid, state)}

      result ->
        # Filled since the caller's own lookup missed (or it never looked):
        # answer straight from the cache.
        send(pid, {:mastodon_posts, handle, result})
        {:noreply, state}
    end
  end

  # The single-flight core: a miss either joins the waiter list of the fetch
  # already running for this handle — never a second fetch — or starts the one
  # supervised fetch task.
  defp start_or_join(handle, pid, state) do
    if Map.has_key?(state.inflight, handle) do
      put_in(state.inflight[handle], [pid | state.inflight[handle]])
    else
      task =
        Task.Supervisor.async_nolink(Vutuv.TaskSupervisor, fn ->
          Mastodon.fetch_posts(handle)
        end)

      %{
        state
        | inflight: Map.put(state.inflight, handle, [pid]),
          refs: Map.put(state.refs, task.ref, handle)
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
  # instance still gets its backoff.
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
    {handle, refs} = Map.pop(state.refs, ref)
    {waiters, inflight} = Map.pop(state.inflight, handle, [])

    ttl =
      case record_result(handle, result, state) do
        :reset -> state.posts_ttl
        {:retry_in_minutes, minutes} -> :timer.minutes(minutes)
        :disabled -> @disabled_ttl
      end

    :ets.insert(state.table, {handle, result, System.monotonic_time(:millisecond) + ttl})

    # Waiters that navigated away are dead pids — send/2 to those is a no-op.
    for pid <- waiters, do: send(pid, {:mastodon_posts, handle, result})

    {:noreply, %{state | refs: refs, inflight: inflight}}
  end

  # The backoff bookkeeping must never take the cache down with it; on a DB
  # hiccup fall back to the first rung so nothing is hammered meanwhile.
  defp record_result(handle, result, _state) do
    Mastodon.record_result(handle, result)
  rescue
    error ->
      Logger.warning(
        "mastodon fetch state for #{inspect(handle)} not recorded: #{inspect(error)}"
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
