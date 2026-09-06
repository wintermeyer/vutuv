defmodule Vutuv.ScreenshotBlocklist.Sweeper do
  @moduledoc """
  Works through the hosts whose stored captures were never judged
  (`Vutuv.ScreenshotBlocklist.Backfill`), a small batch at a time, and clears
  away the pictures a new blocklist entry has just invalidated.

  Two jobs, one loop, because the second only ever follows the first: a site
  that is blocked now usually has captures on disk from before it was, and
  those are exactly the consent-dialog pictures the entry exists to prevent.
  The purge is the same one the admin page and the release task run
  (`Vutuv.PageScreenshot.purge_blocklisted/0` and its siblings), so a blocked
  site loses its old previews within a sweep rather than at the next time
  somebody remembers the button.

  The batch is deliberately small: every host costs an inference, three when
  the answer is that something is in the way. Behind
  `:screenshot_page_check` — an installation that does not judge its captures
  needs no backfill either.
  """

  use GenServer

  require Logger

  alias Vutuv.ScreenshotBlocklist
  alias Vutuv.ScreenshotBlocklist.Backfill
  alias Vutuv.ScreenshotBlocklist.Vision

  @interval :timer.minutes(10)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep()
    schedule()
    {:noreply, state}
  end

  # A DB or model hiccup must not take the sweeper down with it; the next tick
  # tries again. Scheduled after the sweep, so a slow batch spaces the next one
  # out instead of queueing back to back.
  defp sweep do
    if Vision.enabled?() do
      case Backfill.check_due() do
        %{checked: 0, unknown: 0} -> :ok
        tally -> report(tally)
      end
    end
  rescue
    error -> Logger.error("Screenshot page-check sweep failed: #{inspect(error)}")
  end

  defp report(%{blocked: blocked} = tally) do
    Logger.info(
      "Screenshot page-check sweep: #{tally.checked} host(s) judged, " <>
        "#{blocked} blocked, #{tally.unknown} without a verdict"
    )

    if blocked > 0, do: purge()
  end

  # The captures a fresh entry has just invalidated, across all three queues.
  defp purge do
    counts = ScreenshotBlocklist.purge_captures()

    Logger.info(
      "Screenshot page-check purge: #{counts.links} profile link(s), " <>
        "#{counts.posts} post(s), #{counts.organizations} organization(s)"
    )
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
