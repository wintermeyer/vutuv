defmodule Vutuv.References.CheckWorker do
  @moduledoc """
  Drains the Arbeitszeugnis check queue (`Vutuv.References.Checks`) — the
  `Vutuv.Moderation.ImageScanWorker` shape: a slow poll catches retries and
  anything a crash left behind, `nudge/0` starts a freshly queued check
  without waiting for the next tick.

  On boot it re-queues checks stranded mid-inference by a restart or a deploy,
  so nothing sits in `running` forever with a member watching it.

  The poll is slower than the image scanner's because a check costs minutes,
  not seconds: there is no point looking every 15 seconds for work that takes
  a quarter of an hour. `nudge/0` covers the case that actually needs to feel
  immediate, which is a member pressing the button.

  Gated by the `:reference_check_worker` config flag (off in tests, which call
  `Checks.deliver_due/1` directly with a stubbed analysis function).
  """

  use GenServer

  require Logger

  alias Vutuv.References.Checks

  @default_interval :timer.seconds(30)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Run due checks now (a cast to an unstarted worker is a harmless no-op)."
  def nudge, do: GenServer.cast(__MODULE__, :drain)

  @impl GenServer
  def init(_opts) do
    Checks.resume_stuck()
    schedule()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast(:drain, state) do
    drain()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    drain()
    schedule()
    {:noreply, state}
  end

  # A database or model hiccup must not take the worker down: the next queued
  # check, or the next poll, simply tries again.
  defp drain do
    Checks.deliver_due()
  rescue
    error -> Logger.error("reference check drain failed: #{inspect(error)}")
  end

  defp schedule do
    if interval = Application.get_env(:vutuv, :reference_check_poll_interval, @default_interval) do
      Process.send_after(self(), :poll, interval)
    end
  end
end
