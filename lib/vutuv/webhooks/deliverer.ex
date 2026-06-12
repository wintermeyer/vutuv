defmodule Vutuv.Webhooks.Deliverer do
  @moduledoc """
  Drains the webhook delivery queue: polls on a slow interval (retries
  become due over time) and is nudged immediately when `Vutuv.Webhooks`
  queues fresh work, so normal deliveries go out within moments. The
  queue lives in the database, so nothing is lost across restarts —
  whatever was pending is picked up by the next poll.

  Tests run with `config :vutuv, :webhook_poll_interval, nil` (no timer,
  no nudge handling) and call `Vutuv.Webhooks.deliver_due/0` directly.
  """

  use GenServer

  @default_interval :timer.seconds(15)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Asks the deliverer to drain soon (fresh work was queued). A cast to the unstarted name (tests) is a no-op."
  def nudge do
    GenServer.cast(__MODULE__, :drain)
  end

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:drain, state) do
    Vutuv.Webhooks.deliver_due()
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    Vutuv.Webhooks.deliver_due()
    schedule()
    {:noreply, state}
  end

  defp schedule do
    if interval = interval() do
      Process.send_after(self(), :poll, interval)
    end
  end

  defp interval do
    Application.get_env(:vutuv, :webhook_poll_interval, @default_interval)
  end
end
