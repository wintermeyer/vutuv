defmodule Vutuv.Organizations.ScreenshotWorker do
  @moduledoc """
  Drains the organization homepage-screenshot queue
  (`Vutuv.Organizations.Screenshots`) — the same shape as
  `Vutuv.Posts.ScreenshotWorker`: a slow poll catches retries and anything a
  crash left behind, `nudge/0` captures a freshly named website without waiting
  for it. Each drain starts with `resume_stuck/0`, so a job the previous release
  died in the middle of is picked up rather than stranded in `capturing`.

  It is its own process rather than a branch of the post worker: `Vutuv.Posts`
  has no business knowing about organizations, and the two queues fill at
  completely different rates — the post one every time somebody links a page,
  this one only when a page names or changes its website (plus the one-off
  backfill of the pages that predate the feature).

  Gated by the `:organization_screenshot_worker` config flag (off in tests,
  which call `Vutuv.Organizations.Screenshots.deliver_due/1` directly with a
  stubbed capture); the actual headless-Chromium capture is additionally gated
  by `:generate_screenshots`.
  """

  use GenServer

  require Logger

  alias Vutuv.Organizations.Screenshots

  @default_interval :timer.seconds(60)

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

  # A DB hiccup while draining must not take the worker down: the next page (or
  # the next poll) simply tries again.
  defp drain do
    Screenshots.deliver_due()
  rescue
    error -> Logger.error("organization screenshot drain failed: #{inspect(error)}")
  end

  defp schedule do
    interval =
      Application.get_env(:vutuv, :organization_screenshot_poll_interval, @default_interval)

    if interval, do: Process.send_after(self(), :poll, interval)
  end
end
