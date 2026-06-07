defmodule Vutuv.Chat.UnreadNotifier do
  @moduledoc """
  Periodically emails members about conversations left unread past the
  debounce delay (see `Vutuv.Chat.send_unread_notifications/0`). All state
  lives in `conversation_participants` columns, so the schedule is
  restart-safe — this process is only the timer.

  Disabled in tests (`config :vutuv, :send_unread_message_emails, false`):
  the run would use the SQL Sandbox connection from a process that does not
  own it. The first run happens one interval after boot, not at boot, so it
  never races app startup.
  """

  use GenServer

  require Logger

  @interval :timer.minutes(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:notify, state) do
    case Vutuv.Chat.send_unread_notifications() do
      0 -> :ok
      count -> Logger.info("Sent #{count} unread-message email(s)")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :notify, @interval)
end
