defmodule Vutuv.TimeZonesTest do
  @moduledoc """
  The offered zone list is checked-in data (issue #1502), so the thing worth
  guarding is that it has not drifted away from the time zone database it was
  generated from — a zone in the settings menu that `DateTime.shift_zone/2`
  cannot resolve would render every stamp in UTC and say nothing about why.
  """
  use ExUnit.Case, async: true

  alias Vutuv.TimeZones

  describe "all/0" do
    test "every offered zone resolves in the time zone database" do
      unknown = Enum.reject(TimeZones.all(), &TimeZones.known?/1)

      assert unknown == [],
             "these offered zones are not in the bundled tzdata: #{inspect(unknown)}"
    end

    test "covers the continents and leads with UTC" do
      assert hd(TimeZones.all()) == "UTC"
      assert "Europe/Berlin" in TimeZones.all()
      assert "America/New_York" in TimeZones.all()
      assert "Asia/Tokyo" in TimeZones.all()
      assert "Australia/Sydney" in TimeZones.all()
    end
  end

  describe "groups/0" do
    test "groups by IANA area without losing or repeating a zone" do
      grouped = Enum.flat_map(TimeZones.groups(), fn {_area, zones} -> zones end)

      assert grouped == TimeZones.all()
      assert {"UTC", ["UTC"]} = hd(TimeZones.groups())
    end

    test "a three-segment identifier is grouped by its first segment" do
      {area, zones} = Enum.find(TimeZones.groups(), fn {area, _} -> area == "America" end)

      assert area == "America"
      assert "America/Argentina/Buenos_Aires" in zones
    end
  end

  describe "known?/1" do
    # The menu is not the boundary of what is accepted: a browser reports
    # whatever name its own ICU build carries, and a sign-up must not be
    # refused (nor the stamp silently dropped) over an alias we do not list.
    test "accepts IANA aliases the offered list leaves out" do
      assert TimeZones.known?("Europe/Kiev")
      assert TimeZones.known?("Asia/Calcutta")
      refute "Europe/Kiev" in TimeZones.all()
    end

    test "refuses anything the database cannot resolve" do
      refute TimeZones.known?("Middle/Earth")
      refute TimeZones.known?("")
      refute TimeZones.known?(nil)
      refute TimeZones.known?(:"Europe/Berlin")
    end
  end
end
