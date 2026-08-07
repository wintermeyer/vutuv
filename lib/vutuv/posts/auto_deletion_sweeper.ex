defmodule Vutuv.Posts.AutoDeletionSweeper do
  @moduledoc """
  The nightly pass of the members' own automatic post deletion (issue #1255,
  `Vutuv.Posts.AutoDeletion`).

  Scheduling mirrors the other nightly workers — one `Process.send_after` aimed
  at the next Berlin-local 00:30, re-armed each day (DST-aware via
  `Vutuv.BerlinTime`), after `Vutuv.Jobs.Sweeper` (:10) and
  `Vutuv.SavedSearches.AlertSweeper` (:20) so the three do not start together.

  **Once per Berlin day per member, and that is a deliberate cadence rather
  than a cheap one.** A post that has just crossed its threshold is in no
  hurry, one pass a day keeps the member's account-activity log to a single
  "N posts deleted" line instead of a stream of them, and it spreads the
  `Delete(Tombstone)` deliveries a large backlog produces.

  Off in tests (`:auto_post_deletion_sweeper`), where a test calls
  `Vutuv.Posts.AutoDeletion.sweep/1` directly.
  """

  use GenServer

  alias Vutuv.BerlinTime
  alias Vutuv.Posts.AutoDeletion

  @trigger_minute 30

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_next()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:run, state) do
    AutoDeletion.sweep(BerlinTime.today())
    schedule_next()
    {:noreply, state}
  end

  defp schedule_next do
    Process.send_after(self(), :run, BerlinTime.ms_until_daily_trigger(@trigger_minute))
  end
end
