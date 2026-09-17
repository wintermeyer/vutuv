defmodule Vutuv.PostAnalytics.TwelveMonthsRunner do
  @moduledoc """
  Runs `Vutuv.PostAnalytics.TwelveMonths` (the last 12 months) in the background for
  the investor page and keeps the answer for a while.

  **One run, however many people watch.** The investor page is the kind of URL
  that gets passed around, so a run per page view would turn one shared link
  into a burst of 12-month aggregates. A viewer who arrives mid-run joins it
  and hears its remaining steps; a viewer who arrives within `ttl` of the last
  run gets its result straight away. After that the old result is still shown
  while the next run works, so a returning reader never faces an empty card.

  **Progress is broadcast** on a PubSub topic as `{:reach, message}`:
  `:started` when a run begins, `{:step, step}` as each step finishes,
  `{:done, result}` at the end, and `:failed` when the run crashed. Nothing is
  retried on its own: the next viewer starts a new run, which is the whole
  recovery a read-only computation needs, since a run killed by a deploy leaves
  nothing half-written behind.

  **Without a runner** (tests, where `:reach_runner` is off because the
  run's database work would happen outside the SQL sandbox) `watch/1` answers
  `:no_runner` and the caller computes for itself, and `fetch/1` computes in
  place. The agent formats of the page use `fetch/1`, the page itself
  `watch/1` and `peek/1`.

  Each release slot runs its own runner and keeps its own result; the two
  answers differ by at most the data that changed between their runs.
  """
  use GenServer

  alias Vutuv.PostAnalytics.TwelveMonths

  @pubsub Vutuv.PubSub
  @topic "investors:reach"
  @ttl :timer.minutes(10)
  @fetch_timeout :timer.seconds(30)

  @doc """
  Subscribes the caller to the runner's progress and returns what there is to
  show: `%{result:, steps:, running?:}`, where `steps` are those the run in
  flight has finished. Starts a run unless a fresh result is at hand.
  `:no_runner` when none is running.
  """
  def watch(server \\ __MODULE__) do
    with_runner(server, fn -> :no_runner end, fn pid ->
      Phoenix.PubSub.subscribe(@pubsub, GenServer.call(pid, :topic))
      GenServer.call(pid, :watch)
    end)
  end

  @doc """
  What there is to show right now, without subscribing and without starting a
  run: for a page's dead render, which a crawler may request as often as it
  likes.
  """
  def peek(server \\ __MODULE__) do
    with_runner(server, fn -> %{result: nil, steps: [], running?: false} end, fn pid ->
      GenServer.call(pid, :peek)
    end)
  end

  @doc """
  The result, waiting for a run when no fresh one is at hand, or `nil`
  when that run failed or outlasted the wait and none succeeded before it: an
  agent-format page then goes without the sentence rather than failing.
  Computes in the caller when no runner is running.
  """
  def fetch(server \\ __MODULE__) do
    with_runner(server, &TwelveMonths.compute/0, fn pid ->
      GenServer.call(pid, :fetch, @fetch_timeout)
    end)
  catch
    :exit, {:timeout, _call} -> nil
  end

  defp with_runner(server, fallback, fun) do
    case GenServer.whereis(server) do
      nil -> fallback.()
      pid -> fun.(pid)
    end
  end

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    # `name: nil` (isolated test instances) starts the process unregistered.
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       topic: Keyword.get(opts, :topic, @topic),
       ttl: Keyword.get(opts, :ttl, @ttl),
       compute: Keyword.get(opts, :compute, &TwelveMonths.compute/1),
       result: nil,
       finished_at: nil,
       run: nil,
       steps: [],
       waiting: []
     }}
  end

  @impl true
  def handle_call(:topic, _from, state), do: {:reply, state.topic, state}

  def handle_call(:peek, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:watch, _from, state) do
    state = if fresh?(state), do: state, else: ensure_run(state)
    {:reply, snapshot(state), state}
  end

  def handle_call(:fetch, from, state) do
    if fresh?(state) do
      {:reply, state.result, state}
    else
      {:noreply, state |> ensure_run() |> Map.update!(:waiting, &[from | &1])}
    end
  end

  @impl true
  # A task sends its steps before its reply and sends nothing after it, so a
  # step always belongs to the run in flight.
  def handle_info({:reach_step, step}, %{run: %Task{}} = state) do
    broadcast(state, {:step, step})
    {:noreply, %{state | steps: state.steps ++ [step]}}
  end

  def handle_info({ref, result}, %{run: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    broadcast(state, {:done, result})
    Enum.each(state.waiting, &GenServer.reply(&1, result))

    {:noreply,
     %{
       state
       | result: result,
         finished_at: System.monotonic_time(:millisecond),
         run: nil,
         steps: [],
         waiting: []
     }}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{run: %Task{ref: ref}} = state) do
    broadcast(state, :failed)
    # A waiting agent-format request still gets the last result there was.
    Enum.each(state.waiting, &GenServer.reply(&1, state.result))
    {:noreply, %{state | run: nil, steps: [], waiting: []}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp fresh?(%{result: nil}), do: false

  defp fresh?(state),
    do: System.monotonic_time(:millisecond) - state.finished_at < state.ttl

  defp ensure_run(%{run: %Task{}} = state), do: state

  defp ensure_run(state) do
    runner = self()
    compute = state.compute

    task =
      Task.Supervisor.async_nolink(Vutuv.TaskSupervisor, fn ->
        compute.(progress: &send(runner, {:reach_step, &1}))
      end)

    broadcast(state, :started)
    %{state | run: task, steps: []}
  end

  defp snapshot(state) do
    %{result: state.result, steps: state.steps, running?: not is_nil(state.run)}
  end

  defp broadcast(state, message),
    do: Phoenix.PubSub.broadcast(@pubsub, state.topic, {:reach, message})
end
