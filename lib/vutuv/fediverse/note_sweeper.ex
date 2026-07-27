defmodule Vutuv.Fediverse.NoteSweeper do
  @moduledoc """
  The hard ceiling under everything vutuv caches from other networks: the
  replies written under members' posts (issue #1069) and the posts of the
  accounts members follow (issue #1161).

  Everything else that deletes a remote reply depends on somebody doing
  something: the author withdrawing it, the member taking it down, a reader
  reporting it, the operator blocking the server, or the on-view freshness check
  noticing it is gone from its origin. Each of those can fail to happen — the
  `Delete` never arrives because the server was down or we defederated, and a
  copy nobody has opened in months is never checked at all.

  So once an hour this deletes every note whose `expires_at` has passed, and
  that is the promise the privacy page can actually make: six months from
  arrival at the very latest, whatever else does or does not happen. A note
  confirmed still published at its origin pushes that date forward
  (`Vutuv.Fediverse.refresh_note/1`), so a reply people keep reading tracks its
  original while an abandoned copy is collected.

  Nothing is logged per row — an expiry run can remove thousands and would
  drown the ledger, which exists for member takedowns. The count goes to the log
  in aggregate, the way `Vutuv.Fediverse.FollowerPruner` reports.

  Gated twice, like the pruner: the child starts only when
  `:fediverse_note_sweeping` is on (off in tests, so it never touches the SQL
  sandbox from outside), and it is a no-op while `:fediverse_enabled` is off.
  """

  use GenServer

  require Logger

  alias Vutuv.Fediverse

  @interval :timer.hours(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      if Fediverse.enabled?(), do: sweep()
    rescue
      error -> Logger.error("Fediverse sweep failed: #{inspect(error)}")
    end

    schedule()
    {:noreply, state}
  end

  # Four deletions, all of them "the reason for this copy is gone":
  #
  #   * replies past their ceiling (issue #1069),
  #   * cached posts from followed accounts past theirs (issue #1161),
  #   * cached posts whose author nobody here follows any more. The unfollow
  #     paths purge those immediately; this is what catches the follows that
  #     vanished through a cascade — a deleted member account, a purged
  #     instance — without anybody calling the purge.
  #   * stored accounts nothing refers to any more (issue #1162). Last, so it
  #     sees the rows the three above just freed.
  defp sweep do
    log("expired remote reply", Fediverse.expire_due_notes())
    log("expired cached post", Fediverse.expire_due_remote_posts())
    log("cached post of an unfollowed account", Fediverse.purge_unfollowed_remote_posts())
    log("remote account nothing refers to", Fediverse.purge_unreferenced_remote_accounts())
  end

  defp log(_what, 0), do: :ok
  defp log(what, count), do: Logger.info("Fediverse sweep: deleted #{count} #{what}(s)")

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
