defmodule Vutuv.Fediverse.MediaRefetcher do
  @moduledoc """
  Asks again for the pictures whose bytes never arrived (issue #1803).

  `Vutuv.Fediverse.Media.fetch_async/1` runs the first attempt on
  `Vutuv.TaskSupervisor`, fire and forget, off the inbox's request path. What
  the shape has no answer for is the attempt that dies: a blue/green deploy
  stops the slot mid-download, a crash takes the task with it, a server has a
  bad ten seconds — and none of that is logged anywhere, because a refusal is
  not an error the inbox needs to hear about. The row then keeps `file IS NULL`
  for ever, and `Vutuv.Moderation.ImageScans.repair_drift/0` will not rescue it:
  that backstop deliberately skips a picture with no bytes to judge
  (`require_file: true`), which is correct and leaves exactly this gap.

  So the unfinished work is a row, and this is the thing whose standing job is
  to find it and run it again — the shape `Vutuv.Newsletters.BroadcastResumer`
  and the eighteen other sweepers here use. It is cheap because the queue is
  almost always empty: in a healthy minute the due query matches nothing, and
  the interval only has to be short enough that a reader still looking at the
  card gets the picture (13 rows were stuck on production when this was written,
  the oldest three weeks old, and every one of their source URLs answered when
  asked again).

  Gated twice, like the follower pruner: the child starts only when
  `:fediverse_media_fetch` is on (off in tests, where it would reach outside the
  SQL sandbox), and a run is a no-op while `:fediverse_enabled` is off — an
  installation that must not call out.
  """

  use GenServer

  require Logger

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Media

  # Deliberately shorter than `Media`'s backoff (5 min): a tick and a wait of the
  # same length beat against each other, so half the ticks find a row a second
  # short of due and the ladder silently runs at half speed — the trap
  # `Vutuv.Fediverse.CountsRefresher` records for its own interval.
  @interval :timer.minutes(2)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      case sweep() do
        0 -> :ok
        count -> Logger.info("Fediverse media refetch: tried #{count} picture(s) again")
      end
    rescue
      error -> Logger.error("Fediverse media refetch failed: #{inspect(error)}")
    end

    schedule()
    {:noreply, state}
  end

  defp sweep do
    if Fediverse.enabled?(), do: Media.refetch_due(), else: 0
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
