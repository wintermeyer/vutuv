defmodule Vutuv.AccountEvents.Sweeper do
  @moduledoc """
  Deletes account-activity events past their retention window
  (`Vutuv.AccountEvents.retention_days/0`, one year by default).

  The log is personal data, so "keep it forever" is not an option: a year
  covers the "this happened months ago and I only noticed now" support case
  while keeping the table from becoming a permanent movement profile of every
  member's devices and IP addresses.

  Runs daily. Disabled in tests (`config :vutuv, :sweep_account_events, false`):
  the sweep would use the SQL Sandbox connection from a process that does not
  own it — tests call `Vutuv.AccountEvents.delete_expired/0` directly. The first
  sweep runs one interval after boot, not at boot, so it never races startup.
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
    case Vutuv.AccountEvents.delete_expired() do
      0 -> :ok
      count -> Logger.info("Deleted #{count} expired account event(s)")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
