defmodule VutuvWeb.Live.FeedTimeTravelTest do
  @moduledoc """
  The `/feed` time-travel arithmetic. Pure functions, no database.

  The claim worth stating up front: a calendar day is a **window**, not an
  upper bound. `day_cursor/1` carries a lower bound as well, which is what
  makes "show me Tuesday" mean Tuesday rather than Tuesday and all of history
  under it — and the bound rides in the cursor so that it survives pagination.
  """
  use ExUnit.Case, async: true

  alias Vutuv.ViewerClock
  alias VutuvWeb.Live.FeedTimeTravel, as: Travel

  describe "the calendar's day window" do
    test "a day is bounded at both ends, unlike a rail vantage" do
      # The whole difference between clicking a date and dragging the rail to
      # it. Without the lower bound, "show me Tuesday" shows Tuesday and then
      # every earlier day under it as the reader scrolls.
      yesterday = Date.add(ViewerClock.today(), -1)

      cursor = Travel.day_cursor(yesterday)

      assert %{at: last, since: first, ids: []} = cursor
      assert ViewerClock.date(first) == yesterday
      assert ViewerClock.date(last) == yesterday
      assert NaiveDateTime.compare(first, last) == :lt
    end

    test "the window really is the whole day, not a slice of it" do
      day = Date.add(ViewerClock.today(), -3)

      {first, last} = Travel.day_window(day)

      # A whole day, allowing for the second `23:59:59` leaves off and for a
      # DST day that is an hour shorter or longer than the other 364.
      seconds = NaiveDateTime.diff(last, first, :second)
      assert seconds in [82_799, 86_399, 89_999]
    end

    test "today is bounded at now, not at a midnight that has not happened" do
      cursor = Travel.day_cursor(ViewerClock.today())

      assert NaiveDateTime.compare(cursor.at, Travel.now()) != :gt
    end

    test "a future day has no window" do
      assert Travel.day_cursor(Date.add(ViewerClock.today(), 3)) == nil
      assert Travel.day_cursor(nil) == nil
    end

    test "reachable?/1 refuses tomorrow" do
      today = ViewerClock.today()

      assert Travel.reachable?(today)
      assert Travel.reachable?(Date.add(today, -400))
      refute Travel.reachable?(Date.add(today, 1))
    end

    test "parse_date/1 refuses anything that is not a date" do
      assert Travel.parse_date("2026-08-25") == {:ok, ~D[2026-08-25]}
      assert Travel.parse_date("../../etc/passwd") == :error
      assert Travel.parse_date("") == :error
      assert Travel.parse_date(nil) == :error
    end
  end

  describe "the calendar's month grid" do
    test "is always six whole weeks, Monday first" do
      # Fixed height on purpose: a month that would fit in five rows still gets
      # six, so paging months does not resize the card and shove the rail
      # cards below it up and down.
      for month <- [~D[2026-02-01], ~D[2026-08-01], ~D[2026-11-01]] do
        grid = Travel.month_grid(month)

        assert length(grid) == 42
        assert Date.day_of_week(hd(grid).date) == 1
        assert Enum.map(grid, & &1.date) == Enum.sort(Enum.map(grid, & &1.date), Date)
      end
    end

    test "marks which cells belong to the month being shown" do
      grid = Travel.month_grid(~D[2026-08-01])
      in_month = Enum.filter(grid, & &1.in_month?)

      assert length(in_month) == 31
      assert hd(in_month).date == ~D[2026-08-01]
      assert List.last(in_month).date == ~D[2026-08-31]
    end

    test "a February grid still spans six weeks" do
      grid = Travel.month_grid(~D[2026-02-01])

      assert Enum.count(grid, & &1.in_month?) == 28
      assert length(grid) == 42
    end
  end

  describe "shift_month/2" do
    test "steps months and years without overflowing a short month" do
      # `Date.add/2` walks days, so a naive month step from the 31st lands in
      # the wrong month. `month_of/1` normalises to the first, but the
      # arithmetic underneath still has to be day-safe.
      assert Travel.shift_month(~D[2026-03-01], -1) == ~D[2026-02-01]
      assert Travel.shift_month(~D[2026-01-01], -1) == ~D[2025-12-01]
      assert Travel.shift_month(~D[2026-03-01], -12) == ~D[2025-03-01]
    end

    test "never pages into the future" do
      # A calendar that offers next month is offering days nobody can click.
      this_month = Travel.month_of(nil)

      assert Travel.shift_month(this_month, 1) == this_month
      assert Travel.shift_month(this_month, 12) == this_month
      assert Travel.shift_month(Travel.shift_month(this_month, -1), 1) == this_month
    end

    test "month_of/1 normalises whatever it is handed" do
      assert Travel.month_of(~D[2026-08-25]) == ~D[2026-08-01]
      assert Travel.month_of(nil) == Date.beginning_of_month(ViewerClock.today())
    end
  end
end
