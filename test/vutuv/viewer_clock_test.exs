defmodule Vutuv.ViewerClockTest do
  @moduledoc """
  The per-reader clock (issue #1502): which zone a stamp is written in, which
  shape it takes, and the three-layer resolution the Locale plug and the
  LiveView mounts both run through `put_viewer/2`.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Accounts.User
  alias Vutuv.ViewerClock

  describe "put_viewer/2" do
    test "a member's own settings win over everything else" do
      ViewerClock.put_viewer(%User{date_region: "US", time_zone: "America/Denver"}, "GB")

      assert ViewerClock.region() == "US"
      assert ViewerClock.zone() == "America/Denver"
      assert ViewerClock.own_zone?()
    end

    # The middle layer exists so an existing member stops reading US-style
    # stamps the moment they arrive, without having to find the setting first.
    test "the browser guess fills an unset region" do
      ViewerClock.put_viewer(%User{date_region: nil, time_zone: nil}, "US")

      assert ViewerClock.region() == "US"
    end

    test "an anonymous visitor with no usable header gets the installation defaults" do
      ViewerClock.put_viewer(nil, nil)

      assert ViewerClock.region() == Vutuv.Prefs.default(:date_region)
      assert ViewerClock.zone() == Vutuv.Prefs.default(:time_zone)
    end

    # A request carries no time zone, so an inherited zone is a guess the
    # browser can improve on — which is what keeps `local_time/1`'s client-side
    # rewrite in charge for anyone who never chose.
    test "own_zone? is false whenever the zone was inherited" do
      ViewerClock.put_viewer(%User{date_region: "US", time_zone: nil}, "US")

      refute ViewerClock.own_zone?()
      assert ViewerClock.zone() == Vutuv.Prefs.default(:time_zone)
    end

    test "a blank stored value counts as unset" do
      ViewerClock.put_viewer(%User{date_region: "", time_zone: ""}, "GB")

      assert ViewerClock.region() == "GB"
      refute ViewerClock.own_zone?()
    end
  end

  describe "naive/1" do
    test "shifts a UTC instant into the viewer's zone" do
      ViewerClock.put("ISO", "Asia/Tokyo", true)
      assert ViewerClock.naive(~N[2020-01-15 10:00:00]) == ~N[2020-01-15 19:00:00]

      ViewerClock.put("ISO", "America/New_York", true)
      assert ViewerClock.naive(~U[2020-01-15 10:00:00Z]) == ~N[2020-01-15 05:00:00]
    end

    test "follows the zone's own daylight saving rule" do
      ViewerClock.put("ISO", "Europe/Berlin", true)

      # CET in January (+1), CEST in July (+2).
      assert ViewerClock.naive(~N[2026-01-15 10:00:00]) == ~N[2026-01-15 11:00:00]
      assert ViewerClock.naive(~N[2026-07-15 10:00:00]) == ~N[2026-07-15 12:00:00]
    end

    # A tzdata release can retire a zone under a member who is still holding it.
    # A stamp an hour off is a nuisance; a 500 on the feed is not.
    test "an unresolvable zone falls back to UTC instead of raising" do
      ViewerClock.put("ISO", "Middle/Earth", true)

      assert ViewerClock.naive(~N[2020-01-15 10:00:00]) == ~N[2020-01-15 10:00:00]
    end
  end

  describe "date/1 and today/0" do
    test "the calendar day is the viewer's, not UTC's" do
      # 22:30 UTC is already tomorrow in Tokyo and still today in New York.
      at = ~N[2020-01-15 22:30:00]

      ViewerClock.put("ISO", "Asia/Tokyo", true)
      assert ViewerClock.date(at) == ~D[2020-01-16]

      ViewerClock.put("ISO", "America/New_York", true)
      assert ViewerClock.date(at) == ~D[2020-01-15]
    end

    test "today/0 reads the same clock" do
      ViewerClock.put("ISO", "Etc/UTC", true)

      assert ViewerClock.today() == Date.utc_today()
    end
  end

  describe "format/2" do
    test "writes an instant in the viewer's zone and shape" do
      at = ~N[2026-06-20 09:30:00]

      ViewerClock.put("DE", "Europe/Berlin", true)
      assert ViewerClock.format(at, :datetime) == "20.06.2026 11:30"
      assert ViewerClock.format(at, :short_datetime) == "20.06.26, 11:30"
      assert ViewerClock.format(at, :date) == "20.06.2026"
      assert ViewerClock.format(at, :time) == "11:30"

      ViewerClock.put("US", "America/New_York", true)
      assert ViewerClock.format(at, :datetime) == "6/20/2026 5:30 AM"
      assert ViewerClock.format(at, :short_datetime) == "6/20/26, 5:30 AM"

      ViewerClock.put("ISO", "Etc/UTC", true)
      assert ViewerClock.format(at, :datetime_seconds) == "2026-06-20 09:30:00"
    end
  end
end
