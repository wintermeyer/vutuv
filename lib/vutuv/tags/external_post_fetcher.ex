defmodule Vutuv.Tags.ExternalPostFetcher do
  @moduledoc """
  The standing job behind a followed tag's other servers (issue #2126): every
  couple of minutes it asks `Vutuv.Tags.ExternalPosts` which (tag, server) pairs
  are due and works through them.

  The interval here is not the cadence. A pair is asked at its own pace, ten
  minutes to three hours; this loop only decides how finely that pace can be
  hit. It is deliberately well under the floor, for the reason the counts
  refresher beside it spells out: a run stamps a pair a few seconds *after* it
  became due, so a loop ticking exactly at the floor would leave it a few
  seconds short on the next tick and silently double the real interval.

  The next tick is scheduled after the run finishes, so runs cannot pile up on a
  slow network. The child starts only when `:fetch_external_tag_posts` is on —
  off in tests, where its work would use the SQL sandbox connection from a
  process that does not own it, and off on an installation that must not call
  out at all. Tests call `Vutuv.Tags.ExternalPosts.fetch_due/0` directly.

  It also drives the trending pass (#2129), on the same tick and with no counter
  of its own: `Vutuv.Tags.Trending.refresh/0` answers from its own due query and
  returns in microseconds on the twenty-nine ticks out of thirty where nothing
  is due. A schedule kept in this process's state would not survive a restart,
  and this one is a row.
  """

  use GenServer

  require Logger

  alias Vutuv.Tags.ExternalPosts
  alias Vutuv.Tags.Trending

  @interval :timer.minutes(2)

  # How many runs apart the housekeeping goes — an hour at the interval above.
  # What `prune/0` reacts to is somebody dropping a source or unfollowing a tag,
  # which no fetch can bring about, and both its deletes scan a table to find
  # nothing on an ordinary day; running that beside every fetch would pay for a
  # state change that happens a handful of times a week 720 times a day.
  @prune_every 30

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{runs: 0}}
  end

  @impl true
  def handle_info(:fetch, %{runs: runs} = state) do
    try do
      log(ExternalPosts.fetch_due())
      log_trending(Trending.refresh())
      log_own(ExternalPosts.drop_written_here())
      if rem(runs, @prune_every) == 0, do: log_prune(ExternalPosts.prune())
    rescue
      error -> Logger.error("External tag fetch failed: #{inspect(error)}")
    end

    schedule()
    {:noreply, %{state | runs: runs + 1}}
  end

  # A quiet run is the normal one, and it says nothing.
  defp log(%{fetched: 0, skipped: 0, failed: 0}), do: :ok

  defp log(tally) do
    Logger.info(
      "External tag posts: #{tally.fetched} timeline(s) read, #{tally.stored} post(s) stored, " <>
        "#{tally.skipped} skipped, #{tally.failed} failed"
    )
  end

  # Nothing due is the answer on twenty-nine ticks out of thirty, and it says
  # nothing; so does an installation that asks nobody.
  defp log_trending(%{asked: 0}), do: :ok
  defp log_trending(:disabled), do: :ok

  defp log_trending(tally) do
    Logger.info(
      "Trending tags: #{tally.asked} server(s) asked, #{tally.offered} offered, " <>
        "#{tally.hurried} pull(s) hurried, #{tally.skipped} skipped, #{tally.failed} failed"
    )
  end

  # Our own posts coming back as somebody else's find (issue #2179). On every
  # tick rather than with the hourly housekeeping above, and the difference from
  # `prune/0` is what it costs: a host `in` — a sequential scan, since the only
  # index on `author_host` is partial on `reported_at IS NOT NULL` and the
  # `OR … LIKE ANY` beside it would rule one out anyway — plus a substring test
  # over a table capped at ten thousand rows measures 7 ms there and 0.3 ms at
  # today's size, against two correlated `NOT EXISTS` deletes across two
  # tables. The rows
  # it clears are filed by the *previous* release during a blue/green window, and
  # a member reading their own post three times should not wait an hour for it.
  # On an ordinary run it deletes nothing and says nothing.
  defp log_own(0), do: :ok

  defp log_own(dropped),
    do: Logger.info("External tag posts: dropped #{dropped} post(s) written here")

  defp log_prune(%{fetches: 0, posts: 0}), do: :ok

  defp log_prune(%{fetches: fetches, posts: posts}) do
    Logger.info(
      "External tag posts: forgot #{fetches} unwanted pair(s) and #{posts} of their post(s)"
    )
  end

  defp schedule, do: Process.send_after(self(), :fetch, @interval)
end
