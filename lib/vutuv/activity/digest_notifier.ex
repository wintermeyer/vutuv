defmodule Vutuv.Activity.DigestNotifier do
  @moduledoc """
  The timer behind `Vutuv.Activity.Digest`. All state lives in the database
  (`users.notifications_notified_at`), so this process holds nothing worth
  keeping and a restart resumes exactly where the last sweep left off.

  The same shape as `Vutuv.Chat.UnreadNotifier`, including the two things that
  matter for a scheduled job here: the first run is one interval **after** boot
  rather than at boot, so it never races app startup, and a failed sweep is
  logged and re-scheduled instead of taking the process down — a model being
  slow or a mail server refusing once must not stop every later digest.

  Disabled in tests (`config :vutuv, :send_notification_digest_emails, false`):
  a run would use the SQL Sandbox connection from a process that does not own
  it. Tests call `Vutuv.Activity.Digest.send_pending/0` directly.
  """

  use GenServer

  require Logger

  alias Vutuv.Activity.Digest

  @interval :timer.minutes(5)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule()
    {:noreply, state}
  end

  defp sweep do
    case Digest.send_pending() do
      0 -> :ok
      count -> Logger.info("Sent #{count} notification digest email(s)")
    end
  rescue
    error -> Logger.error("notification digest sweep failed: #{Exception.message(error)}")
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
