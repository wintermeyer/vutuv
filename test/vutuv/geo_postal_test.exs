defmodule Vutuv.GeoPostalTest do
  use ExUnit.Case, async: true

  alias Vutuv.Geo

  describe "coordinates/2" do
    test "resolves a known German postal code offline" do
      assert {lat, lon} = Geo.coordinates("DE", "50667")
      # 50667 is central Cologne (~50.94 N, 6.95 E).
      assert_in_delta lat, 50.94, 0.2
      assert_in_delta lon, 6.95, 0.2
    end

    test "resolves Austria and Switzerland too" do
      assert {_, _} = Geo.coordinates("AT", "1010")
      assert {_, _} = Geo.coordinates("CH", "8001")
    end

    test "normalises whitespace and case in the input" do
      assert Geo.coordinates("de", " 50667 ") == Geo.coordinates("DE", "50667")
    end

    test "returns nil for an unknown postal code" do
      assert Geo.coordinates("DE", "00000") == nil
    end

    test "returns nil for a country without bundled data" do
      assert Geo.coordinates("US", "10001") == nil
    end

    test "returns nil for non-binary input" do
      assert Geo.coordinates(nil, "50667") == nil
      assert Geo.coordinates("DE", nil) == nil
    end
  end

  describe "place_coordinates/2" do
    test "resolves a place name" do
      assert {_, _} = Geo.place_coordinates("DE", "Köln")
    end
  end

  describe "config accessors" do
    test "geo_countries and default_country expose the configured values" do
      assert "DE" in Geo.geo_countries()
      assert Geo.default_country() == "DE"
    end
  end
end
