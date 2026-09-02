defmodule Vutuv.Videos.Pipeline do
  @moduledoc """
  The scheduler behind video on posts (issue #1910): runs `Vutuv.Videos.Job`
  for at most `concurrency` clips at once (two by default — the transcode is
  the heaviest thing this server does on a member's behalf, and a burst of
  uploads must queue rather than take the site down), picks up work every
  few seconds or when an upload nudges it, and after a deploy or a crash
  resumes every clip whose job died with its process.

  The due list is a query, never state in this process
  (`Vutuv.Videos.claim_due/1`): a claim is a compare-and-set on the row's
  heartbeat, so the two slots of a blue/green deploy can overlap without
  working the same clip twice, and a row nobody has touched for
  `Vutuv.Videos.stale_after_seconds/0` is simply claimed again.

  Off in tests (`:video_pipeline`), which drive the job directly.
  """

  use GenServer

  require Logger

  alias Vutuv.Videos
  alias Vutuv.Videos.Job

  @poll_ms :timer.seconds(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "An upload landed: look for work now rather than at the next poll."
  def nudge do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :nudge)
    :ok
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, false)
    send(self(), :poll)
    {:ok, %{running: %{}}}
  end

  @impl true
  def handle_cast(:nudge, state), do: {:noreply, fill(state)}

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, fill(state)}
  end

  # A job finished (its result is irrelevant: everything it decided is on the
  # row) or died. Either way the slot is free and the next poll re-claims the
  # clip if it still has work — a stale heartbeat is how a crash is found.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, fill(drop(state, ref))}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if reason != :normal,
      do: Logger.warning("video job crashed video=#{state.running[ref]} reason=#{inspect(reason)}")

    {:noreply, fill(drop(state, ref))}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp drop(state, ref), do: %{state | running: Map.delete(state.running, ref)}

  defp fill(state) do
    free = Videos.concurrency() - map_size(state.running)

    if free > 0 and Videos.enabled?() do
      free
      |> Videos.claim_due()
      |> Enum.reduce(state, fn video, acc ->
        task = Task.Supervisor.async_nolink(Vutuv.TaskSupervisor, Job, :run, [video.id])
        %{acc | running: Map.put(acc.running, task.ref, video.id)}
      end)
    else
      state
    end
  end
end
