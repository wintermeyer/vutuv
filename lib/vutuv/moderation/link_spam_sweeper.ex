defmodule Vutuv.Moderation.LinkSpamSweeper do
  @moduledoc """
  The clock of `Vutuv.Moderation.LinkSpam`: every 30 minutes it runs the check
  that freezes a new account registered to plant a link.

  The first tick comes five minutes after boot rather than half an hour,
  because this site deploys several times a day and a full interval after
  every boot could keep pushing the check back.

  Disabled in tests (`config :vutuv, :link_spam_check, false`): the run would
  touch the SQL Sandbox from a process that does not own it, so tests call
  `Vutuv.Moderation.LinkSpam.run/1` directly.
  """

  use GenServer

  require Logger

  alias Vutuv.Moderation.LinkSpam

  @first_tick :timer.minutes(5)
  @interval :timer.minutes(30)

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
    # Rescued, like the sign-up trap's reporter: a raise would restart the
    # process, which would then wait out a fresh first tick.
    try do
      case LinkSpam.run() do
        0 -> :ok
        frozen -> Logger.info("Link spam check froze #{frozen} new account(s)")
      end
    rescue
      error -> Logger.error("Link spam check failed: #{Exception.message(error)}")
    end

    Process.send_after(self(), :tick, @interval)
    {:noreply, state}
  end
end
