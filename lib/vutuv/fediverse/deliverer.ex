defmodule Vutuv.Fediverse.Deliverer do
  @moduledoc """
  Drains the outbound ActivityPub delivery queue (`Vutuv.Fediverse.Delivery`)
  — the same shape as `Vutuv.Webhooks.Deliverer`: a slow poll catches retries
  and anything a crash left behind, `nudge/0` delivers new activities without
  waiting for it. Gated by the `:fediverse_deliverer` config flag (off in
  tests, which call `Vutuv.Fediverse.deliver_due/0` directly).
  """

  use GenServer

  @default_interval :timer.seconds(15)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Deliver now (a cast to an unstarted deliverer is a harmless no-op)."
  def nudge, do: GenServer.cast(__MODULE__, :drain)

  @impl GenServer
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast(:drain, state) do
    Vutuv.Fediverse.deliver_due()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    Vutuv.Fediverse.deliver_due()
    schedule()
    {:noreply, state}
  end

  defp schedule do
    if interval = Application.get_env(:vutuv, :fediverse_poll_interval, @default_interval) do
      Process.send_after(self(), :poll, interval)
    end
  end
end
