defmodule Vutuv.PageScreenshot.Sweeper do
  @moduledoc """
  Captures the profile links that are still waiting for a screenshot
  (`Vutuv.PageScreenshot.due/1`), a small batch at a time.

  The link form fires its capture off the request path and forgets it, which is
  fine right up to the moment the task does not finish: a blue/green deploy
  stops the slot mid-capture and nobody hears about it. And a link the form
  never saw — the LinkedIn import inserts them straight through `Repo` — had
  nothing capturing it in the first place. Either way the member kept a grey
  camera tile forever, because nothing ever looked at the link again.

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
