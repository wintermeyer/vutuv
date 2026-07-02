defmodule Vutuv.DayClock do
  @moduledoc """
  Broadcasts a `:day_changed` message on the `"clock:day"` PubSub topic at each
  Europe/Berlin midnight, so every open LiveView that renders Berlin-dated post
  timestamps (`VutuvWeb.UI.post_time/1` on the feed, profile and notifications)
  can re-render them the moment the German calendar day rolls over: a post made
  "today" (shown as a bare "09:50 Uhr") must become "Gestern, 09:50 Uhr" at
  00:00, and yesterday's must fall back to the full date. Without this an open
  page keeps the stale wording until its next reload or live update.

  There is no server-side state to update; the clock is a pure fan-out timer. It
  schedules one `Process.send_after/3` for the next Berlin midnight
  (`Vutuv.BerlinTime.next_midnight_utc/0`, DST-aware) plus a few seconds of slack
  so timer drift can never fire it in the last millisecond of the old day (which
  would broadcast the stale date), then reschedules on every tick.
  """
  use GenServer

  alias Phoenix.PubSub
  alias Vutuv.BerlinTime

  @topic "clock:day"
  @slack_ms :timer.seconds(5)

  @doc "The PubSub topic the day-boundary broadcast is published on."
  def topic, do: @topic

  @doc "Subscribe the calling process to the Berlin day-boundary broadcast."
  def subscribe, do: PubSub.subscribe(Vutuv.PubSub, @topic)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, schedule(%{})}

  @impl true
  def handle_info(:midnight, state) do
    PubSub.broadcast(Vutuv.PubSub, @topic, :day_changed)
    {:noreply, schedule(state)}
  end

  # Arm the timer for the next Berlin midnight (plus slack), keeping its ref so
  # the process can be inspected/torn down cleanly.
  defp schedule(state) do
    ms = DateTime.diff(BerlinTime.next_midnight_utc(), DateTime.utc_now(), :millisecond)
    timer = Process.send_after(self(), :midnight, max(ms, 0) + @slack_ms)
    Map.put(state, :timer, timer)
  end
end
