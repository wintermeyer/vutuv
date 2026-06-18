defmodule Vutuv.AddressTest do
  use ExUnit.Case, async: true

  alias Vutuv.Address
  alias Vutuv.Profiles.Address, as: Record

  defp address(attrs) do
    struct(Record, Map.merge(%{country: "Germany"}, Map.new(attrs)))
  end

  describe "lines/2" do
    test "renders a German address with its country for a non-de viewer" do
      a = address(line_1: "Johannes-Müller-Str. 10", zip_code: "56068", city: "Koblenz")

      assert Address.lines(a, "en") == ["Johannes-Müller-Str. 10", "56068 Koblenz", "Deutschland"]
      assert Address.lines(a, nil) == ["Johannes-Müller-Str. 10", "56068 Koblenz", "Deutschland"]
    end

    test "drops the country line for a German address shown to a de viewer" do
      a = address(line_1: "Johannes-Müller-Str. 10", zip_code: "56068", city: "Koblenz")

      assert Address.lines(a, "de") == ["Johannes-Müller-Str. 10", "56068 Koblenz"]
    end

    test "keeps the country for a foreign address even for a de viewer" do
      a = address(country: "France", line_1: "10 Rue de Rivoli", zip_code: "75001", city: "Paris")

      assert Address.lines(a, "de") == ["10 Rue de Rivoli", "75001 Paris", "France"]
    end

    test "formats US addresses as City, ST ZIP" do
      a =
        address(
          country: "United States",
          line_1: "1 Infinite Loop",
          city: "Cupertino",
          state: "CA",
          zip_code: "95014"
        )

      assert Address.lines(a, "en") == ["1 Infinite Loop", "Cupertino, CA 95014", "United States"]
    end

    test "skips blank lines" do
      a = address(line_1: nil, line_2: "", zip_code: "56068", city: "Koblenz")

      assert Address.lines(a, "de") == ["56068 Koblenz"]
    end

    test "a country-only German address renders nothing for a de viewer" do
      a = address(line_1: nil, line_2: nil, zip_code: nil, city: nil)

      assert Address.lines(a, "de") == []
      assert Address.lines(a, "en") == ["Deutschland"]
    end
  end

  describe "map_links/1" do
    test "builds Google, OpenStreetMap and Apple deep links" do
      a = address(line_1: "Johannes-Müller-Str. 10", zip_code: "56068", city: "Koblenz")
      links = Address.map_links(a)

      assert Keyword.keys(links) == [:google, :openstreetmap, :apple]

      for {_service, url} <- links do
        # The geocoding query keeps the country even though a de viewer never
        # sees it on screen, so the pin still resolves.
        assert url =~ "Germany"
        assert url =~ "Koblenz"
        # The street is percent-encoded (ü -> %C3%BC).
        assert url =~ "M%C3%BCller"
      end

      assert links[:google] =~ "https://www.google.com/maps/search/?api=1&query="
      assert links[:openstreetmap] =~ "https://www.openstreetmap.org/search?query="
      assert links[:apple] =~ "https://maps.apple.com/?q="
    end
  end
end
