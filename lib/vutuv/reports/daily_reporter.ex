defmodule Vutuv.Reports.DailyReporter do
  @moduledoc """
  The daily-report clockwork. Just after midnight (00:05 German local time)
  it mails the *previous* German calendar day's activity report to the
  operator through `Vutuv.Reports.deliver_daily_email/1`, which itself skips
  any day whose every metric is zero.

  Unlike the polling sweepers, this schedules itself for the exact next
  trigger instant and sleeps until then, a real cron tick rather than a busy
  poll. After firing it reschedules for the following day, so a DST shift is
  picked up each time (the trigger is computed in Berlin local time via
  `Vutuv.BerlinTime`). The marker is implicit in the timer, so a restart in
  the few minutes between local midnight and the trigger can miss that one
  day's mail. That is harmless for a stats notice and rare (it only coincides
  with a deploy landing in that window). Disabled in tests
  (`config :vutuv, :daily_report_email, false`), same SQL-Sandbox reasoning as
  the other periodic jobs; tests call `Vutuv.Reports` directly.
  """

  use GenServer

  require Logger

  alias Vutuv.BerlinTime
  alias Vutuv.Reports

  # Minutes past German-local midnight to fire. Five minutes' grace lets the
  # finishing day's last writes settle before it is tallied.
  @trigger_minute 5

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
    yesterday = Date.add(BerlinTime.today(), -1)

    case Reports.deliver_daily_email(yesterday) do
      {:ok, _report} -> Logger.info("Mailed the daily report for #{yesterday}")
      :skipped -> :ok
    end

    schedule_next()
    {:noreply, state}
  end

  defp schedule_next do
    Process.send_after(self(), :run, ms_until_next_trigger())
  end

  # Milliseconds from now until the next German-local 00:05, computed in UTC
  # off the Berlin-day midnight instants so it lands on the wall-clock minute
  # through both DST halves.
  defp ms_until_next_trigger do
    now = DateTime.to_naive(DateTime.utc_now())
    today = BerlinTime.today()
    today_trigger = trigger_instant(today)

    target =
      if NaiveDateTime.compare(now, today_trigger) == :lt do
        today_trigger
      else
        trigger_instant(Date.add(today, 1))
      end

    max(NaiveDateTime.diff(target, now, :millisecond), 0)
  end

  # The 00:05-Berlin instant of `date`, as a UTC NaiveDateTime.
  defp trigger_instant(date) do
    {midnight_utc, _day_end} = BerlinTime.day_bounds_utc(date)
    NaiveDateTime.add(midnight_utc, @trigger_minute * 60, :second)
  end
end
