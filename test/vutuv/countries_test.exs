defmodule Vutuv.CountriesTest do
  use ExUnit.Case, async: true

  alias Vutuv.Countries

  describe "valid?/1" do
    test "accepts known uppercase alpha-2 codes" do
      assert Countries.valid?("DE")
      assert Countries.valid?("US")
      assert Countries.valid?("GB")
    end

    test "rejects lowercase, unknown, empty, nil, and non-binary input" do
      refute Countries.valid?("de")
      refute Countries.valid?("XX")
      refute Countries.valid?("")
      refute Countries.valid?(nil)
      refute Countries.valid?(123)
    end
  end

  describe "name/2" do
    test "returns the English name for the en locale" do
      assert Countries.name("DE", "en") == "Germany"
      assert Countries.name("US", "en") == "United States"
      assert Countries.name("GB", "en") == "United Kingdom"
    end

    test "returns the German name for the de locale" do
      assert Countries.name("DE", "de") == "Deutschland"
      assert Countries.name("AT", "de") == "Österreich"
      assert Countries.name("CH", "de") == "Schweiz"
    end

    test "accepts locale atoms as well as strings" do
      assert Countries.name("DE", :de) == "Deutschland"
      assert Countries.name("DE", :en) == "Germany"
    end

    test "unknown locale falls back to English" do
      assert Countries.name("DE", "fr") == "Germany"
    end

    test "unknown or invalid code returns the uppercased code" do
      assert Countries.name("XX", "en") == "XX"
      assert Countries.name("xx", "en") == "XX"
      assert Countries.name(nil, "en") == ""
    end

    test "nil locale uses the current gettext locale" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      assert Countries.name("DE") == "Deutschland"
      Gettext.put_locale(VutuvWeb.Gettext, "en")
      assert Countries.name("DE") == "Germany"
    after
      Gettext.put_locale(VutuvWeb.Gettext, "en")
    end
  end

  describe "select_options/1" do
    test "returns {name, code} tuples and contains the German name for de" do
      options = Countries.select_options(:de)
      assert {"Deutschland", "DE"} in options
      assert {"Österreich", "AT"} in options
    end

    test "returns English names for en" do
      options = Countries.select_options(:en)
      assert {"Germany", "DE"} in options
      assert {"Austria", "AT"} in options
    end

    test "options are sorted by the folded localized name" do
      options = Countries.select_options(:de)
      keys = Enum.map(options, fn {name, _code} -> Countries.fold(name) end)
      assert keys == Enum.sort(keys)
    end

    test "German folding sorts Österreich near O, not after Z" do
      options = Countries.select_options(:de)
      names = Enum.map(options, fn {name, _code} -> name end)
      oesterreich = Enum.find_index(names, &(&1 == "Österreich"))
      poland = Enum.find_index(names, &(&1 == "Polen"))
      assert oesterreich < poland
    end
  end

  describe "uses_state?/1" do
    test "true for federations that use a state or province in addresses" do
      assert Countries.uses_state?("US")
      assert Countries.uses_state?("CA")
    end

    test "false for countries that address by city and postal code" do
      refute Countries.uses_state?("DE")
      refute Countries.uses_state?("FR")
      refute Countries.uses_state?(nil)
    end
  end

  describe "names/2" do
    test "pairs codes with their localized names, sorted like the option list" do
      assert Countries.names(~w(CH AT DE), :de) == [
               {"Deutschland", "DE"},
               {"Österreich", "AT"},
               {"Schweiz", "CH"}
             ]
    end

    test "drops unknown codes and collapses duplicates" do
      assert Countries.names(~w(DE XX de DE), :en) == [{"Germany", "DE"}]
      assert Countries.names([], :en) == []
      assert Countries.names(nil, :en) == []
    end
  end

  describe "search/2" do
    test "matches a fragment of the localized name" do
      assert {"Deutschland", "DE"} in Countries.search("eutschl", :de)
      assert {"Germany", "DE"} in Countries.search("germ", :en)
    end

    test "folds diacritics and case on both sides" do
      # The point of the folding: nobody types an umlaut into a search box.
      assert {"Österreich", "AT"} in Countries.search("oster", :de)
      assert {"Côte d'Ivoire", "CI"} in Countries.search("COTE", :de)
    end

    test "an exact ISO code is listed first" do
      assert [{"Österreich", "AT"} | _rest] = Countries.search("AT", :de)
      assert [{"Italien", "IT"} | _rest] = Countries.search("it", :de)
    end

    test "names that begin with the query come before matches buried mid-word" do
      # Alphabetical order alone answered "sch" with Amerikanisch-Samoa,
      # Aserbaidschan and Bangladesch, and pushed Schweiz past the eight hits a
      # picker shows.
      top = Countries.search("sch", :de) |> Enum.take(4) |> Enum.map(&elem(&1, 0))
      assert "Schweden" in top
      assert "Schweiz" in top

      # A later word counts too: "staaten" finds "Vereinigte Staaten".
      assert [{"Vereinigte Staaten", "US"} | _rest] = Countries.search("staaten", :de)
    end

    test "a blank or non-binary query finds nothing" do
      assert Countries.search("", :de) == []
      assert Countries.search("   ", :de) == []
      assert Countries.search(nil, :de) == []
    end
  end

  describe "regions/1" do
    test "the four presets carry localized names and their size" do
      assert ["EU", "EMEA", "MENA", "APAC"] == Enum.map(Countries.regions(:de), & &1.key)

      eu = Enum.find(Countries.regions(:de), &(&1.key == "EU"))
      assert eu.name == "Europäische Union"
      assert eu.count == 27
      assert eu.count == length(Countries.region_codes("EU"))

      assert Enum.find(Countries.regions(:en), &(&1.key == "EU")).name == "European Union"
    end

    test "the EU expansion is the 27 member states" do
      eu = Countries.region_codes("EU")
      assert "DE" in eu
      refute "CH" in eu
      refute "GB" in eu
    end

    test "EMEA is the union of Europe, the Middle East and Africa" do
      emea = Countries.region_codes("EMEA")
      # One from each of the three parts, and nothing from the Americas or APAC.
      assert "NO" in emea
      assert "SA" in emea
      assert "KE" in emea
      refute "US" in emea
      refute "JP" in emea
      assert Enum.uniq(emea) == emea
    end

    test "region_codes/1 answers [] for anything unknown" do
      assert Countries.region_codes("LATAM") == []
      assert Countries.region_codes(nil) == []
    end
  end

  describe "region_for/1" do
    test "names the region a selection covers exactly, in any order" do
      assert Countries.region_for(Countries.region_codes("EU")) == "EU"
      assert Countries.region_for(Enum.reverse(Countries.region_codes("APAC"))) == "APAC"
    end

    test "a selection that is not exactly a region is not named as one" do
      # Taking one country back out means something narrower than the region,
      # and calling it "EU" anyway would misdescribe where they will hire.
      [_dropped | rest] = Countries.region_codes("EU")
      assert Countries.region_for(rest) == nil
      assert Countries.region_for(["DE", "AT"]) == nil
      assert Countries.region_for([]) == nil
    end
  end

  describe "all/0" do
    test "covers the full ISO 3166-1 alpha-2 set" do
      codes = Countries.all()
      assert length(codes) >= 240
      assert "DE" in codes
      assert Enum.all?(codes, &(&1 == String.upcase(&1)))
    end
  end
end
