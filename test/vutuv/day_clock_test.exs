defmodule Vutuv.DayClockTest do
  @moduledoc """
  The day-boundary clock fans a single `:day_changed` message out to every
  subscriber (the post-showing LiveViews) at Berlin midnight, so open pages can
  re-render Berlin-dated post timestamps ("09:50 Uhr" -> "Gestern, 09:50 Uhr").
  We drive the `:midnight` callback directly instead of waiting ~24h for the
  real timer to fire.
  """
  use ExUnit.Case, async: true

  alias Vutuv.DayClock

  test "subscribers receive :day_changed when the clock reaches midnight" do
    DayClock.subscribe()

    assert {:noreply, _state} = DayClock.handle_info(:midnight, %{})
    assert_receive :day_changed
  end

  test "handling a midnight tick reschedules the next one" do
    # The returned state carries the fresh timer ref, so the clock keeps ticking
    # day after day rather than firing once and going silent.
    assert {:noreply, %{timer: timer}} = DayClock.handle_info(:midnight, %{})
    assert is_reference(timer)
  end
end
