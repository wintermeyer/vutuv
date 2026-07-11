defmodule Vutuv.Profiles.LinkRecheckSweeper do
  @moduledoc """
  Periodically re-checks verified personal-webpage links
  (`Vutuv.Profiles.LinkVerification.recheck_due_links/0`). A link whose proof
  (rel=me back-link, DNS record or well-known file) has vanished enters a grace
  window; once it passes the link loses its verified mark.

  Gated twice: the child is started only when `:recheck_user_links` is on (off
  in tests, so it never touches the SQL sandbox from outside), and the actual
  re-check is a no-op when `:verify_user_links` is off (intranet installs that
  must not call out).
  """

  use GenServer

  require Logger

  alias Vutuv.Profiles.LinkVerification

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
      case LinkVerification.recheck_due_links() do
        0 -> :ok
        count -> Logger.info("Link re-check: #{count} link(s) lost verified status")
      end
    rescue
      error -> Logger.error("Link re-check failed: #{inspect(error)}")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
