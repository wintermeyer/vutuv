defmodule Vutuv.Accounts.UnconfirmedRegistrationSweeper do
  @moduledoc """
  Periodically deletes accounts that registered but never confirmed their login
  PIN, an hour after sign-up (see `Vutuv.Accounts.delete_unconfirmed_registrations/1`).
  Without this, every abandoned sign-up (including bot/typo registrations) would
  linger as an unverified account forever.

  Only registration-born unconfirmed accounts are reaped: the delete is guarded
  so it can never touch a legacy member who merely failed to log in. Runs every
  15 minutes, so an abandoned registration is gone within ~60-75 minutes.

  Disabled in tests (`config :vutuv, :sweep_unconfirmed_registrations, false`):
  the sweep would use the SQL Sandbox connection from a process that does not own
  it. The first sweep runs one interval after boot, not at boot, so it never
  races app startup.
  """

  use GenServer

  require Logger

  @interval :timer.minutes(15)

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
    case Vutuv.Accounts.delete_unconfirmed_registrations() do
      0 -> :ok
      count -> Logger.info("Deleted #{count} unconfirmed registration(s)")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
