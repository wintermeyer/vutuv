defmodule Vutuv.SignupTrap.Reporter do
  @moduledoc """
  The clock of `Vutuv.SignupTrap`'s weekly report. Once an hour it calls
  `Vutuv.SignupTrap.run/2`, which deletes the expired entries and mails a
  finished week if one is waiting.

  Hourly rather than a timer aimed at Monday 07:00, on purpose: what is due is
  a query over the entries, not something this process remembers, so a
  restart, a deploy or a crash at the wrong minute costs an hour's delay and
  never a week's report. The first tick comes five minutes after boot rather
  than an hour, because this site deploys several times a day and a full hour
  after every boot could keep pushing the Monday mail back.

  Disabled in tests (`config :vutuv, :signup_trap_report, false`): the run
  would touch the SQL Sandbox from a process that does not own it, so tests
  call `Vutuv.SignupTrap.run/2` directly.
  """

  use GenServer

  require Logger

  @first_tick :timer.minutes(5)
  @interval :timer.hours(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, @first_tick)
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    # Rescued, like the daily report: a raise would restart the process, which
    # would then wait out a fresh first tick, and the log would say nothing.
    try do
      case Vutuv.SignupTrap.run() do
        %{deleted: 0, reported: 0} -> :ok
        result -> Logger.info("Sign-up trap: #{inspect(result)}")
      end
    rescue
      error -> Logger.error("Sign-up trap tick failed: #{Exception.message(error)}")
    end

    Process.send_after(self(), :tick, @interval)
    {:noreply, state}
  end
end
