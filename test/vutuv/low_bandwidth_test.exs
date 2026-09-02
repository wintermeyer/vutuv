defmodule Vutuv.LowBandwidthTest do
  @moduledoc """
  The per-process flag behind data-saving mode. What the renderers read is
  `on?/0`, and the two things that matter about it are that it answers for
  the viewer this process was told about and for nobody else, and that a
  process nobody told anything answers off — a lite picture goes only to a
  viewer known to want one.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Accounts.User
  alias Vutuv.LowBandwidth

  test "a process nobody told anything is off" do
    refute LowBandwidth.on?()
  end

  test "put_viewer/1 resolves the member's preference and returns it" do
    assert LowBandwidth.put_viewer(%User{low_bandwidth?: true})
    assert LowBandwidth.on?()

    refute LowBandwidth.put_viewer(%User{low_bandwidth?: false})
    refute LowBandwidth.on?()
  end

  # NULL inherits the installation default, exactly as `Vutuv.Prefs` resolves
  # it everywhere else (the shipped default is off).
  test "an undecided member and a visitor get the installation default" do
    refute LowBandwidth.put_viewer(%User{low_bandwidth?: nil})
    refute LowBandwidth.put_viewer(nil)
  end

  test "put/1 sets it directly, for a test that renders as either viewer" do
    LowBandwidth.put(true)
    assert LowBandwidth.on?()
    LowBandwidth.put(false)
    refute LowBandwidth.on?()
  end

  test "the flag is the process's own" do
    LowBandwidth.put(true)
    assert Task.await(Task.async(fn -> LowBandwidth.on?() end)) == false
  end

  test "the cookie has a stable name the proxy can route on" do
    assert LowBandwidth.cookie_name() == "vutuv_low_bandwidth"
  end
end
