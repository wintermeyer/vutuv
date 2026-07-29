defmodule Vutuv.Profiles.SocialAccountRecheckSweeper do
  @moduledoc """
  Periodically re-checks verified social-media handles
  (`Vutuv.Profiles.SocialAccountVerification.recheck_due_accounts/0`). An
  account whose proof (the vutuv profile URL in its Bluesky bio) has vanished
  enters a grace window; once it passes the account loses its verified mark.

  Gated twice, like its webpage-link sibling: the child is started only when
  `:recheck_social_accounts` is on (off in tests, so it never touches the SQL
  sandbox from outside), and the re-check itself is a no-op when
  `:verify_social_accounts` is off (intranet installs that must not call out).
  """

  use GenServer

  require Logger

  alias Vutuv.Profiles.SocialAccountVerification

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
      case SocialAccountVerification.recheck_due_accounts() do
        0 -> :ok
        count -> Logger.info("Social account re-check: #{count} account(s) lost verified status")
      end
    rescue
      error -> Logger.error("Social account re-check failed: #{inspect(error)}")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
