defmodule Vutuv.Fediverse.FollowerPruner do
  @moduledoc """
  Drops remote followers whose account no longer exists (issue #1072).

  A remote who unfollows sends `Undo(Follow)` and one who deletes their account
  broadcasts a `Delete`, and both remove the row at once. Neither reaches us
  when a server just stops answering for one of its accounts: deliveries go to
  that server's shared inbox, which keeps working for everybody else on it, so
  the row would sit here forever — inflating the member's follower count and
  keeping an online identifier of somebody who left.

  So once an hour this re-fetches a small batch of due follower rows with the
  SSRF-guarded, size-capped, signed `Vutuv.Fediverse.fetch_remote_actor/2` and
  deletes the ones answered with `404` or `410`. Everything else (a timeout, a
  connection error, a `5xx`, a `429`) leaves the row alone — see
  `Vutuv.Fediverse.prune_due_followers/1` for the batch, per-server and
  re-check-interval caps that keep this a trickle rather than a sweep.

  Gated twice: the child starts only when `:fediverse_follower_pruning` is on
  (off in tests, so it never touches the SQL sandbox from outside), and the
  re-check itself is a no-op while `:fediverse_enabled` is off (an installation
  that must not call out).
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
      case Fediverse.prune_due_followers() do
        0 -> :ok
        count -> Logger.info("Fediverse follower prune: removed #{count} gone follower(s)")
      end

      # The same rotation pointed the other way (issue #1168): accounts our
      # members follow, which vanish just as silently as followers do. One
      # sweep, two directions, so the per-host bounds stay comparable.
      case Fediverse.prune_due_remote_accounts() do
        0 -> :ok
        count -> Logger.info("Fediverse account prune: removed #{count} gone account(s)")
      end
    rescue
      error -> Logger.error("Fediverse follower prune failed: #{inspect(error)}")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
