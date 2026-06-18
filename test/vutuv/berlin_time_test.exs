defmodule Vutuv.BerlinTimeTest do
  @moduledoc """
  The German calendar-day rule (DST window, last-Sunday math) lives in
  `Vutuv.BerlinTime` now that the ad rotation and the profile age display
  share it. Test it at its real home; `Vutuv.Ads.berlin_date/1` is only a
  back-compat delegate and will be retired in a later deploy.
  """
  use ExUnit.Case, async: true

  alias Vutuv.BerlinTime

  describe "date/1" do
    test "applies CET in winter and CEST in summer" do
      assert BerlinTime.date(~U[2026-01-10 22:30:00Z]) == ~D[2026-01-10]
      assert BerlinTime.date(~U[2026-01-10 23:30:00Z]) == ~D[2026-01-11]
      assert BerlinTime.date(~U[2026-07-10 21:30:00Z]) == ~D[2026-07-10]
      assert BerlinTime.date(~U[2026-07-10 22:30:00Z]) == ~D[2026-07-11]
    end

    test "switches on the last Sundays of March and October, 01:00 UTC" do
      # 2026: DST starts March 29, ends October 25.
      assert BerlinTime.date(~U[2026-03-29 00:59:00Z]) == ~D[2026-03-29]
      assert BerlinTime.date(~U[2026-03-29 22:30:00Z]) == ~D[2026-03-30]
      assert BerlinTime.date(~U[2026-10-25 00:30:00Z]) == ~D[2026-10-25]
      assert BerlinTime.date(~U[2026-10-25 22:30:00Z]) == ~D[2026-10-25]
    end
  end

  describe "day_bounds_utc/1" do
    test "brackets a winter day with the CET (+1h) offset" do
      assert BerlinTime.day_bounds_utc(~D[2026-01-15]) ==
               {~N[2026-01-14 23:00:00], ~N[2026-01-15 23:00:00]}
    end

    test "brackets a summer day with the CEST (+2h) offset" do
      assert BerlinTime.day_bounds_utc(~D[2026-07-15]) ==
               {~N[2026-07-14 22:00:00], ~N[2026-07-15 22:00:00]}
    end

    test "the bounds round-trip: every instant inside maps back to that Berlin day" do
      for date <- [~D[2026-01-15], ~D[2026-07-15]] do
        {start, finish} = BerlinTime.day_bounds_utc(date)
        first = DateTime.from_naive!(start, "Etc/UTC")
        last = finish |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(-1, :second)
        before = DateTime.add(first, -1, :second)

        assert BerlinTime.date(first) == date
        assert BerlinTime.date(last) == date
        assert BerlinTime.date(before) == Date.add(date, -1)
      end
    end
  end

  describe "today/0" do
    test "is a Date on or after the current UTC day (Berlin is never behind UTC)" do
      today = BerlinTime.today()
      assert %Date{} = today
      assert Date.compare(today, Date.utc_today()) in [:eq, :gt]
    end
  end
end
