defmodule Vutuv.ApiAuth.Sweeper do
  @moduledoc """
  Periodically clears the two OAuth tables that fill up on their own
  (`Vutuv.ApiAuth.sweep/0`, issue #1557): unattended client registrations nobody
  ever consented to, and authorization codes that are long spent.

  It only ever **deletes**, so it has none of the "least recently done first"
  hazard the other sweepers carry: there is no clock to stamp and no batch that
  can be blocked forever by an item that can never be worked on. Every pass
  makes the set strictly smaller.

  Disabled in tests (`config :vutuv, :sweep_api_auth, false`) like its siblings:
  the sweep would use the SQL Sandbox connection from a process that does not own
  it. The first pass runs one interval after boot, not at boot, so it never races
  app startup.
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
    case Vutuv.ApiAuth.sweep() do
      %{apps: 0, codes: 0} ->
        :ok

      %{apps: apps, codes: codes} ->
        Logger.info("Swept #{apps} abandoned app registration(s) and #{codes} spent code(s)")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
