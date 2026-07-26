defmodule Vutuv.Posts.DraftSweeper do
  @moduledoc """
  Periodically removes composer drafts nobody has touched in a month
  (`Vutuv.Posts.sweep_drafts/1`, issue #1148).

  A draft is a convenience, not an archive: keeping one forever would mean the
  composer eventually greets someone with half a sentence they have long
  forgotten writing, and it would keep the photos attached to it alive with it
  (`sweep_pending_images/1` spares anything a live draft still names). A month
  is long enough for "I'll finish this after the holiday".

  Disabled in tests (`config :vutuv, :sweep_post_drafts, false`): the sweep
  would use the SQL Sandbox connection from a process that does not own it.
  The first sweep runs one interval after boot, not at boot, so it never races
  app startup.
  """

  use GenServer

  require Logger

  @interval :timer.hours(24)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    case Vutuv.Posts.sweep_drafts() do
      0 -> :ok
      count -> Logger.info("Swept #{count} abandoned composer draft(s)")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
