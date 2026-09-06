defmodule Vutuv.Moderation.Sweeper do
  @moduledoc """
  The moderation clockwork, every 15 minutes:

    * escalates `pending_owner` cases whose 72h self-service deadline has
      passed into the admin queue (`Vutuv.Moderation.escalate_overdue/0`);
    * once a day (the first sweep after #{7}:00 UTC) sends the admin digest
      email when cases are waiting (`Vutuv.Moderation.Notifier.admins_digest/1`);
    * finishes any half-done picture freeze or restore
      (`Vutuv.Images.reconcile_holds/0`). A copyright freeze moves files, and a
      deploy that stops the slot between two renames leaves the job unfinished
      with nothing in a log to say so — so the row's `frozen_at` is the record
      and this is the thing that acts on it;
    * drops public notices nobody confirmed inside their week
      (`Vutuv.Moderation.sweep_expired_notices/0`, issue #2009). Such a row
      counts for nothing and its link no longer works, so left alone it is a
      `flagged` case in the admin queue that nothing can ever act on.

  The "digest already sent today" marker is in-memory, so a restart on a
  digest day can repeat the mail once - harmless, admins can take a second
  nudge. Disabled in tests (`config :vutuv, :moderation_sweeper, false`),
  same SQL-Sandbox reasoning as the other sweepers.
  """

  use GenServer

  require Logger

  alias Vutuv.Images
  alias Vutuv.Moderation
  alias Vutuv.Moderation.Notifier

  @interval :timer.minutes(15)
  @digest_hour_utc 7

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{digest_sent_on: nil}}
  end

  @impl true
  def handle_info(:sweep, state) do
    case Moderation.escalate_overdue() do
      0 -> :ok
      count -> Logger.info("Escalated #{count} overdue moderation case(s) to the admin queue")
    end

    Images.reconcile_holds()

    case Moderation.sweep_expired_notices() do
      0 -> :ok
      count -> Logger.info("Dropped #{count} unconfirmed report notice(s) past their deadline")
    end

    state = maybe_send_digest(state)
    schedule()
    {:noreply, state}
  end

  defp maybe_send_digest(%{digest_sent_on: sent_on} = state) do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    if now.hour >= @digest_hour_utc and sent_on != today do
      Notifier.admins_digest(Moderation.open_queue_count())
      %{state | digest_sent_on: today}
    else
      state
    end
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
