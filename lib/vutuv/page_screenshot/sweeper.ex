defmodule Vutuv.PageScreenshot.Sweeper do
  @moduledoc """
  Captures the profile links that are still waiting for a screenshot
  (`Vutuv.PageScreenshot.due/0`), a small batch at a time.

  The link form used to fire a capture task off the request path and forget
  it, which was fine right up to the moment the task did not finish: a
  blue/green deploy stops the slot mid-capture and nobody hears about it. And a
  link the form never saw (the LinkedIn import inserts them straight through
  `Repo`) had nothing capturing it in the first place. Either way the member
  kept a grey camera tile forever, because nothing ever looked at the link
  again. Now every save only nudges this process (`nudge/0`).

  So the unfinished work is recorded where the dying process does not own it,
  in the row itself, and this is the standing job that finds it and runs it
  again. A capture is idempotent and cheap, so it repeats the whole thing
  rather than resuming anything.

  Behind `:generate_screenshots`, the same flag the captures themselves ride
  on: an installation that takes no screenshots needs no sweeper, and the test
  suite (where it is off) drives `capture_due/1` directly.
  """

  use GenServer

  require Logger

  alias Vutuv.PageScreenshot

  @interval :timer.minutes(5)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Sweeps now rather than at the next tick, so a member who just saved a link
  (or imported an archive of them) sees the picture arrive. Fire it after the
  write commits, or the sweep finds no row yet.

  Every capture goes through this one process, so at most one Chromium runs
  for profile links however fast somebody saves them. The link form used to
  start a task per save, and a script writing links through the API could
  start browsers until the host ran out of memory. A cast to a sweeper that is
  not running (tests, an installation without screenshots) does nothing.
  """
  def nudge, do: GenServer.cast(__MODULE__, :sweep)

  @impl GenServer
  def handle_cast(:sweep, state) do
    drop_queued_nudges()
    sweep()
    {:noreply, state}
  end

  # A burst of saves queues a nudge each, and one sweep answers all of them.
  defp drop_queued_nudges do
    receive do
      {:"$gen_cast", :sweep} -> drop_queued_nudges()
    after
      0 -> :ok
    end
  end

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

  # A DB hiccup must not take the sweeper down with it — the next tick tries
  # again. Scheduled after the sweep, so a batch of slow captures spaces the
  # next one out instead of queueing back to back.
  defp sweep do
    case PageScreenshot.capture_due() do
      0 -> :ok
      count -> Logger.info("Link screenshot sweep: #{count} link(s)")
    end
  rescue
    error -> Logger.error("Link screenshot sweep failed: #{inspect(error)}")
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
