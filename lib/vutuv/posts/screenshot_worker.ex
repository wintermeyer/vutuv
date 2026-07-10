defmodule Vutuv.Posts.ScreenshotWorker do
  @moduledoc """
  Drains the post link-screenshot queue (`Vutuv.Posts.Screenshots`) — the same
  shape as `Vutuv.Fediverse.Deliverer`: a slow poll catches retries and anything
  a crash left behind, `nudge/0` captures a freshly posted link without waiting
  for it. On boot it re-queues jobs stuck mid-capture (`resume_stuck/0`), so a
  restart or re-deploy never strands one.

  Gated by the `:post_screenshot_worker` config flag (off in tests, which call
  `Vutuv.Posts.Screenshots.deliver_due/1` directly with a stubbed capture); the
  actual headless-Chromium capture is additionally gated by `:generate_screenshots`.
  """

  use GenServer

  require Logger

  alias Vutuv.Posts.Screenshots

  @default_interval :timer.seconds(15)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Capture now (a cast to an unstarted worker is a harmless no-op)."
  def nudge, do: GenServer.cast(__MODULE__, :drain)

  @impl GenServer
  def init(_opts) do
    Screenshots.resume_stuck()
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

  # A DB hiccup while draining must not take the worker down: the next post (or
  # the next poll) simply tries again.
  defp drain do
    Screenshots.deliver_due()
  rescue
    error -> Logger.error("post screenshot drain failed: #{inspect(error)}")
  end

  defp schedule do
    if interval = Application.get_env(:vutuv, :post_screenshot_poll_interval, @default_interval) do
      Process.send_after(self(), :poll, interval)
    end
  end
end
