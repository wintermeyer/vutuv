defmodule Vutuv.Fediverse.CountsRefresher do
  @moduledoc """
  Keeps the like and repost figures of cached remote objects current (issue
  #1283).

  A post from another network used to carry no numbers at all, and the action
  bar said why: vutuv cannot know how many people liked something on somebody
  else's server. That was half true. Nothing is *delivered* here — a `Like` goes
  to the author's inbox and an `Announce` to the author plus the announcer's
  followers, so a third party's counters never pass through this installation —
  but ActivityPub §5.7 and §5.8 put `likes` and `shares` on the object itself,
  and the servers our members read serve both with a `totalItems`. So the figures
  are knowable; they just have to be asked for.

  This is the asking, and the whole design is about doing it as a good neighbour:

    * **On a ladder, by the object's own age** (`Vutuv.Fediverse.counts_ladder/0`).
      Every five minutes for the first half hour and every ten for the hour
      after that — which is when a post's tally actually moves — then quarter
      hourly to six hours, hourly through its second day, four times a day to a
      week, and then never again. An old post's tally has stopped moving, and
      asking about it is traffic a stranger's server pays for and nobody reads.
    * **Conditionally.** The stored ETag rides along as `If-None-Match`, and a
      `304` costs both sides an empty body. The figures live in the body, so a
      `304` really does mean nothing changed.
    * **In the background only, never on a page render.** Request volume then
      follows how many objects we cache, not how many people are reading them;
      a refresh per render would turn a popular thread into an amplifier.
    * **Bounded per run and per host**, so one instance hosting many of the
      accounts our members follow is spread over several runs, and a backlog
      drains gradually rather than in one spike.
    * **With a doubling backoff per object**, dropping it off the ladder after a
      few strikes. A server having a bad day must never see us return every five
      minutes.

  The run itself is sequential (`Vutuv.Fediverse.refresh_due_counts/0`) and the
  next one is scheduled after it finishes, so runs cannot pile up on a slow
  network.

  Gated twice like the sweeper beside it: the child starts only when
  `:fediverse_counts` is on (off in tests, so it never talks to the network from
  outside the SQL sandbox), and it is a no-op while `:fediverse_enabled` is off.
  """

  use GenServer

  require Logger

  alias Vutuv.Fediverse

  # Well under the ladder's shortest tier, and that margin is the whole point
  # rather than caution. A run stamps `counts_checked_at` a few seconds *after*
  # the moment it became due, so on the next run one tier later the object is a
  # few seconds short of due and waits a whole further run — a five-minute tier
  # polled every five minutes really re-asks every ten. Polling at well under
  # the floor removes that doubling; a run with nothing due costs one indexed
  # query per table.
  @interval :timer.minutes(2)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    try do
      if Fediverse.enabled?(), do: log(Fediverse.refresh_due_counts())
    rescue
      error -> Logger.error("Fediverse counts refresh failed: #{inspect(error)}")
    end

    schedule()
    {:noreply, state}
  end

  # A quiet run is the normal one, and it says nothing.
  defp log(%{updated: 0, failed: 0}), do: :ok

  defp log(tally) do
    Logger.info(
      "Fediverse counts: #{tally.updated} object(s) changed, " <>
        "#{tally.unchanged} unchanged, #{tally.failed} failed, #{tally.skipped} skipped"
    )
  end

  defp schedule, do: Process.send_after(self(), :refresh, @interval)
end
