defmodule Vutuv.DayClock do
  @moduledoc """
  Broadcasts a `:day_changed` message on the `"clock:day"` PubSub topic at every
  whole UTC hour, so every open LiveView that renders day-relative post
  timestamps (`VutuvWeb.UI.post_time/1` on the feed, profile and notifications)
  can re-render them when a calendar day rolls over: a post made "today" (shown
  as a bare "09:50 Uhr") must become "Gestern, 09:50 Uhr" at midnight, and
  yesterday's must fall back to the full date. Without this an open page keeps
  the stale wording until its next reload or live update.

  **Why the hour and not one daily tick.** Post stamps used to be Berlin time for
  everybody, so a single alarm at Berlin midnight covered every reader. Since
  issue #1502 each reader has their own zone (`Vutuv.ViewerClock`), and their
  midnights are spread across the day — but every one of them falls on a whole
  UTC hour, because every zone in the IANA database is offset from UTC by a
  whole number of minutes and the handful with a `:30`/`:45` offset are the only
  ones that settle late (within the hour, on the next tick). Berlin midnight is
  itself a whole UTC hour, so the Berlin-day consumers this clock also feeds —
  `VutuvWeb.ShellLive`'s "new members today" pill — still refresh exactly on it;
  the other 23 ticks merely re-ask a question whose answer has not changed.

  There is no server-side state to update; the clock is a pure fan-out timer. It
  schedules one `Process.send_after/3` for the next whole hour plus a few seconds
  of slack so timer drift can never fire it in the last millisecond of the old
  hour (which would broadcast the stale date), then reschedules on every tick.
  """
  use GenServer

  alias Phoenix.PubSub

  @topic "clock:day"
  @slack_ms :timer.seconds(5)
  @hour_ms :timer.hours(1)

  @doc "The PubSub topic the day-boundary broadcast is published on."
  def topic, do: @topic

  @doc "Subscribe the calling process to the day-boundary broadcast."
  def subscribe, do: PubSub.subscribe(Vutuv.PubSub, @topic)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, schedule(%{})}

  @impl true
  def handle_info(:tick, state) do
    PubSub.broadcast(Vutuv.PubSub, @topic, :day_changed)
    {:noreply, schedule(state)}
  end

  # Arm the timer for the next whole UTC hour (plus slack), keeping its ref so
  # the process can be inspected/torn down cleanly.
  defp schedule(state) do
    now = DateTime.utc_now()
    ms = @hour_ms - rem(DateTime.to_unix(now, :millisecond), @hour_ms)
    timer = Process.send_after(self(), :tick, ms + @slack_ms)
    Map.put(state, :timer, timer)
  end
end
