defmodule Vutuv.Jobs.Sweeper do
  @moduledoc """
  The nightly job-posting lifecycle sweeper (issue #932). Once per Berlin
  calendar day it:

    * e-mails every poster whose posting expires in 7 days ("still open? close
      it as filled, or repost it once it expires"), through the `Emailer`
      chokepoint;
    * flips every overdue published posting to `expired`.

  Demotion to owner-only (a posting expired more than 30 days ago) needs no DB
  write — `Vutuv.Jobs.visible_to?/2` computes it from the dates.

  Scheduling mirrors `Vutuv.Reports.DailyReporter`: a single `Process.send_after`
  aimed at the next Berlin-local 00:10, re-armed each day (DST-aware via
  `Vutuv.BerlinTime`). Off in tests (`:jobs_sweeper`); a test calls `sweep/1`
  directly.
  """

  use GenServer

  require Logger

  alias Vutuv.Accounts
  alias Vutuv.BerlinTime
  alias Vutuv.Jobs
  alias Vutuv.Notifications.Emailer

  @trigger_minute 10
  @reminder_lead_days 7

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_next()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:run, state) do
    sweep(BerlinTime.today())
    schedule_next()
    {:noreply, state}
  end

  @doc """
  Runs one sweep for `today` (Berlin): reminder e-mails + expiry. Returns the
  number of postings expired, so a test can assert on it.
  """
  def sweep(today \\ BerlinTime.today()) do
    send_reminders(today)
    expired = Jobs.expire_overdue(today)
    if expired > 0, do: Logger.info("Jobs.Sweeper expired #{expired} postings")
    expired
  end

  defp send_reminders(today) do
    reminder_date = Date.add(today, @reminder_lead_days)
    reminder_date |> Jobs.postings_expiring_on() |> Enum.each(&deliver_reminder/1)
  end

  defp deliver_reminder(posting) do
    user = posting.user

    Emailer.deliver_async(fn ->
      case Accounts.first_email_value(user) do
        nil ->
          :ok

        address ->
          user |> Emailer.job_posting_expiry_reminder_email(address, posting) |> Emailer.deliver()
      end
    end)
  end

  defp schedule_next do
    Process.send_after(self(), :run, BerlinTime.ms_until_daily_trigger(@trigger_minute))
  end
end
