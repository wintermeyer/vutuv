defmodule Vutuv.Moderation.ImageScanWorker do
  @moduledoc """
  Drains the AI image-moderation queue (`Vutuv.Moderation.ImageScans`) — the
  `Vutuv.Posts.ScreenshotWorker` shape: a slow poll catches retries and
  anything a crash left behind, `nudge/0` scans a fresh upload without
  waiting for it. On boot it re-queues scans stuck mid-inference
  (`resume_stuck/0`) and re-enqueues stranded pending assets
  (`repair_drift/0`), so a restart or re-deploy never leaves an image in
  limbo forever; the drift repair re-runs hourly as the standing backstop.

  Gated by the `:image_scan_worker` config flag (off in tests, which call
  `ImageScans.deliver_due/1` directly with a stubbed judge); the actual
  Ollama call is additionally gated by `:moderate_images`.
  """

  use GenServer

  require Logger

  alias Vutuv.Moderation.ImageScans

  @default_interval :timer.seconds(15)
  # Polls between drift repairs (~hourly at the default interval).
  @drift_every 240

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Scan now (a cast to an unstarted worker is a harmless no-op)."
  def nudge, do: GenServer.cast(__MODULE__, :drain)

  @impl GenServer
  def init(_opts) do
    ImageScans.resume_stuck()
    repair()
    schedule()
    {:ok, %{polls: 0}}
  end

  @impl GenServer
  def handle_cast(:drain, state) do
    drain()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:poll, %{polls: polls} = state) do
    drain()
    polls = polls + 1

    polls =
      if polls >= @drift_every do
        repair()
        0
      else
        polls
      end

    schedule()
    {:noreply, %{state | polls: polls}}
  end

  # A DB or Ollama hiccup must not take the worker down: the next upload (or
  # the next poll) simply tries again.
  defp drain do
    ImageScans.deliver_due()
  rescue
    error -> Logger.error("image scan drain failed: #{inspect(error)}")
  end

  defp repair do
    case ImageScans.repair_drift() do
      0 -> :ok
      count -> Logger.info("image moderation drift repair re-enqueued #{count} scan(s)")
    end
  rescue
    error -> Logger.error("image moderation drift repair failed: #{inspect(error)}")
  end

  defp schedule do
    if interval = Application.get_env(:vutuv, :image_scan_poll_interval, @default_interval) do
      Process.send_after(self(), :poll, interval)
    end
  end
end
