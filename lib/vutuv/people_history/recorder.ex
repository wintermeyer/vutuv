defmodule Vutuv.PeopleHistory.Recorder do
  @moduledoc """
  The clockwork behind the growth curve: at 23:59 German local time it writes
  the closing head count of the day that is ending (`Vutuv.PeopleHistory.record/1`).

  A minute before midnight rather than a few minutes after it, so the row
  carries the date of the day it describes without any arithmetic — the last
  minute of sign-ups it misses lands in tomorrow's row instead, and since both
  figures are running totals rather than per-day deltas, nothing is lost.

  Like the other nightly workers it schedules the exact next trigger instant
  and sleeps until then (`Vutuv.BerlinTime.ms_until_daily_trigger/1`, DST-aware
  because the offset is recomputed on every tick) instead of polling. A restart
  in the last minute of a day can miss that day; `Vutuv.PeopleHistory.series/1`
  reads whatever rows exist, so a gap thins the curve rather than breaking it.

  Disabled in tests (`config :vutuv, :record_people_history, false`) for the
  same reason as every other periodic job here: the write would use the SQL
  Sandbox connection from a process that does not own it. Tests call
  `Vutuv.PeopleHistory` directly.
  """

  use GenServer

  require Logger

  alias Vutuv.BerlinTime
  alias Vutuv.PeopleHistory

  # Minutes past German-local midnight: 23:59 of the same day.
  @trigger_minute 23 * 60 + 59

  @doc "Minutes past Berlin midnight at which the snapshot is taken."
  def trigger_minute, do: @trigger_minute

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_next()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:run, state) do
    case PeopleHistory.record() do
      {:ok, snapshot} ->
        Logger.info(
          "Recorded people snapshot for #{snapshot.day}: " <>
            "#{snapshot.members} members, #{snapshot.fediverse_accounts} Fediverse accounts"
        )

      {:error, changeset} ->
        Logger.error("Could not record the people snapshot: #{inspect(changeset.errors)}")
    end

    schedule_next()
    {:noreply, state}
  end

  defp schedule_next do
    Process.send_after(self(), :run, BerlinTime.ms_until_daily_trigger(@trigger_minute))
  end
end
