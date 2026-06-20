defmodule Vutuv.Deliverability.Sweeper do
  @moduledoc """
  The deliverability clockwork: once a day (the first tick after #{4}:00 UTC) it
  freezes confirmed accounts whose only addresses have been dead past the grace
  period (`Vutuv.Deliverability.sweep_unreachable/0`).

  This is the time-based half of the freeze rule. The per-bounce path can only
  freeze on a *second* hard bounce, but the first bounce stops automatic mail,
  so a member who never logs in again produces no second bounce - the sweep is
  what eventually freezes their long-dead account.

  The "swept today" marker is in-memory: a restart on a sweep day can repeat the
  (idempotent) sweep, which is harmless. Disabled in tests
  (`config :vutuv, :sweep_unreachable_accounts, false`), same SQL-Sandbox
  reasoning as the other sweepers.
  """

  use GenServer

  require Logger

  alias Vutuv.Deliverability

  @interval :timer.hours(1)
  @sweep_hour_utc 4

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{swept_on: nil}}
  end

  @impl true
  def handle_info(:sweep, state) do
    state = maybe_sweep(state)
    schedule()
    {:noreply, state}
  end

  defp maybe_sweep(%{swept_on: swept_on} = state) do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    if now.hour >= @sweep_hour_utc and swept_on != today do
      case Deliverability.sweep_unreachable() do
        0 -> :ok
        count -> Logger.info("Deliverability sweep re-assessed #{count} long-dead account(s)")
      end

      %{state | swept_on: today}
    else
      state
    end
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
