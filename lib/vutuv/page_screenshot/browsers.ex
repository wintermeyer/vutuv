defmodule Vutuv.PageScreenshot.Browsers do
  @moduledoc """
  How many headless Chromiums may run at once, across every capture path.

  Each capture is a browser of its own, a few hundred megabytes while it runs.
  The link, post and organization queues each run one at a time, but a path
  that starts a browser per request (a moderation case's evidence shot, and
  until 2026-09 every saved profile link) could start them faster than they
  finish, and a script doing that runs the host out of memory. All launches
  meet in `Vutuv.PageScreenshot.run/4`, so the cap sits there: a run past it
  waits for a slot rather than failing, since every capture ends within its
  own ceiling of well under a minute.

  A slot belongs to the calling process and comes back when the run returns,
  raises, or the caller dies.
  """

  use GenServer

  @limit 2

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.get(opts, :limit, @limit), name: name)
  end

  @doc """
  Runs `fun` once a slot is free and returns what it returns. Raises
  (exits) when the limiter is not running, so a capture never runs uncounted.
  """
  def run(fun, server \\ __MODULE__) do
    :ok = GenServer.call(server, :checkout, :infinity)

    try do
      fun.()
    after
      GenServer.cast(server, {:checkin, self()})
    end
  end

  @impl GenServer
  def init(limit), do: {:ok, %{limit: limit, busy: %{}, waiting: :queue.new()}}

  @impl GenServer
  def handle_call(:checkout, {pid, _tag} = from, state) do
    ref = Process.monitor(pid)

    if map_size(state.busy) < state.limit do
      {:reply, :ok, put_in(state.busy[ref], pid)}
    else
      {:noreply, %{state | waiting: :queue.in({ref, from}, state.waiting)}}
    end
  end

  @impl GenServer
  def handle_cast({:checkin, pid}, state) do
    case Enum.find(state.busy, fn {_ref, owner} -> owner == pid end) do
      {ref, _owner} ->
        Process.demonitor(ref, [:flush])
        {:noreply, release(state, ref)}

      nil ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    if Map.has_key?(state.busy, ref) do
      {:noreply, release(state, ref)}
    else
      waiting = :queue.filter(fn {waiting_ref, _from} -> waiting_ref != ref end, state.waiting)
      {:noreply, %{state | waiting: waiting}}
    end
  end

  # Frees `ref`'s slot and hands it to the longest waiter, if any.
  defp release(state, ref) do
    busy = Map.delete(state.busy, ref)

    case :queue.out(state.waiting) do
      {{:value, {next_ref, {next_pid, _tag} = from}}, waiting} ->
        GenServer.reply(from, :ok)
        %{state | busy: Map.put(busy, next_ref, next_pid), waiting: waiting}

      {:empty, _waiting} ->
        %{state | busy: busy}
    end
  end
end
