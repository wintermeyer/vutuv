defmodule Vutuv.Organizations.DomainRecheckSweeper do
  @moduledoc """
  Periodically re-checks verified DNS / well-known organization domains
  (`Vutuv.Organizations.recheck_due_domains/0`). A domain whose record/file has
  vanished enters a grace window; once the window passes it loses verified
  status, and if it was the organization's last verified domain the page falls back
  to `pending` and the operator is alerted.

  Gated twice: the child is started only when `:recheck_organization_domains` is on
  (off in tests, so it never touches the SQL sandbox from outside), and the
  actual re-check is a no-op when `:verify_organization_domains` is off (intranet
  installs that must not call out).
  """

  use GenServer

  require Logger

  alias Vutuv.Organizations

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
      case Organizations.recheck_due_domains() do
        0 ->
          :ok

        count ->
          Logger.info("Organization domain re-check: #{count} domain(s) lost verified status")
      end
    rescue
      error -> Logger.error("Organization domain re-check failed: #{inspect(error)}")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
