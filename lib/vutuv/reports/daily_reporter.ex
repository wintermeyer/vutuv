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
  `Vutuv.BerlinTime`). A report that raises is logged and skipped rather than
  taken as a crash, so one bad day is visible in the log instead of vanishing.
  The marker is implicit in the timer, so a restart in
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

    # Deliberately rescued: a raise here used to be invisible. The GenServer
    # died inside its own timer callback, the supervisor restarted it, and
    # `init/1` scheduled the *following* midnight — so a broken report cost
    # that day's mail with no error anywhere the operator would look, and the
    # next night's mail arrived as if nothing had happened. That is exactly how
    # the first Fediverse follower of a page or a topic silently swallowed a
    # day's report (`VutuvWeb.ReportDetails`). Logging the day and the reason
    # keeps the loss visible; rescheduling either way keeps one bad day from
    # taking the following ones with it.
    try do
      case Reports.deliver_daily_email(yesterday) do
        {:ok, _report} -> Logger.info("Mailed the daily report for #{yesterday}")
        :skipped -> :ok
      end
    rescue
      error ->
        Logger.error(
          "Daily report for #{yesterday} failed: #{Exception.format(:error, error, __STACKTRACE__)}"
        )
    end

    schedule_next()
    {:noreply, state}
  end

  defp schedule_next do
    Process.send_after(self(), :run, BerlinTime.ms_until_daily_trigger(@trigger_minute))
  end
end
