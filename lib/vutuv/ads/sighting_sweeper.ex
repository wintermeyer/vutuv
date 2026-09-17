defmodule Vutuv.Ads.SightingSweeper do
  @moduledoc """
  Deletes the seen ads a member's history no longer shows
  (`Vutuv.Ads.forget_old_sightings/1`, #{Vutuv.Ads.sighting_days()} days).

  Which ad somebody was shown is personal data, so it is kept only as long as
  the "seen ads" page offers it.

  The first sweep runs ten minutes after boot and then daily: a deploy restarts
  the node, so an interval counted from boot alone could keep missing the sweep
  on a day with more than one deploy. Repeating it is harmless, since the
  delete is idempotent. Disabled in tests (`config :vutuv, :sweep_ad_sightings,
  false`), which call `forget_old_sightings/1` directly.
  """

  use GenServer

  require Logger

  @first_sweep :timer.minutes(10)
  @interval :timer.hours(24)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule(@first_sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    case Vutuv.Ads.forget_old_sightings() do
      0 -> :ok
      count -> Logger.info("Forgot #{count} old ad sighting(s)")
    end

    schedule(@interval)
    {:noreply, state}
  end

  defp schedule(delay), do: Process.send_after(self(), :sweep, delay)
end
