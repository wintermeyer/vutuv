defmodule Vutuv.DayClockTest do
  @moduledoc """
  The day-boundary clock fans a single `:day_changed` message out to every
  subscriber (the post-showing LiveViews) on every whole UTC hour, so open pages
  can re-render day-relative post timestamps ("09:50 Uhr" -> "Gestern, 09:50
  Uhr") when the reader's own midnight passes. We drive the `:tick` callback
  directly instead of waiting for the real timer to fire.
  """
  use ExUnit.Case, async: true

  alias Vutuv.DayClock

  test "subscribers receive :day_changed on a tick" do
    DayClock.subscribe()

    assert {:noreply, _state} = DayClock.handle_info(:tick, %{})
    assert_receive :day_changed
  end

  test "handling a tick reschedules the next one" do
    # The returned state carries the fresh timer ref, so the clock keeps ticking
    # hour after hour rather than firing once and going silent.
    assert {:noreply, %{timer: timer}} = DayClock.handle_info(:tick, %{})
    assert is_reference(timer)
  end

  test "the next tick is armed for the coming hour, never further out" do
    # Every reader's local midnight falls on a whole UTC hour (Vutuv.ViewerClock),
    # so a clock that drifted past the hour would leave "today" stale on an open
    # page for the rest of the day. The slack is a few seconds, so one hour plus
    # a small margin is the whole budget.
    {:noreply, %{timer: timer}} = DayClock.handle_info(:tick, %{})

    remaining = Process.read_timer(timer)
    assert remaining > 0
    assert remaining <= :timer.hours(1) + :timer.seconds(10)
  end
end
