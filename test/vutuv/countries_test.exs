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
      # `zz` is deliberately not a real ISO 639-1 code, the way the invalid
      # country code below is `XX`: this used to say "fr", which stopped being
      # an unknown locale the day French shipped.
      assert Countries.name("DE", "zz") == "Germany"
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

  # `addresses.country` holds the English name, not the code
  # (`VutuvWeb.AddressHTML.country_options/1`), so a reader in another language
  # needs the name translated back through the code.
  describe "localize_english_name/2" do
    test "translates a stored English name into the reader's language" do
      assert Countries.localize_english_name("United Kingdom", "de") == "Vereinigtes Königreich"
      assert Countries.localize_english_name("Germany", "fr") == "Allemagne"
      assert Countries.localize_english_name("Switzerland", "en") == "Switzerland"
    end

    test "keeps a name outside the ISO list as it is stored" do
      assert Countries.localize_english_name("Burma", "de") == "Burma"
    end

    test "answers nil for no country" do
      assert Countries.localize_english_name(nil, "de") == nil
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

  describe "the table's own spelling rules" do
    # Deliberately not inside the French block below: this is an invariant of
    # every column, and it would stay green if the French one stopped resolving
    # (the English fallback spells its one apostrophe the same way). What it
    # really guards is the next regeneration — CLDR writes the typographic
    # apostrophe, and the generator normalizes it on the way in.
    test "every name uses the ASCII apostrophe, so fold/1 and search reach it" do
      # `fold/1` folds accents and not apostrophes, so a name carrying U+2019 is
      # unreachable by anybody typing `'`.
      carrying =
        for locale <- ~w(en de fr it),
            code <- Countries.all(),
            name = Countries.name(code, locale),
            String.contains?(name, "’"),
            do: "#{locale}/#{code}: #{name}"

      assert carrying == [], "typographic apostrophe in: #{inspect(carrying)}"
    end

    test "the one name with an apostrophe is searchable by typing it" do
      assert Countries.name("CI", "fr") == "Côte d'Ivoire"
      assert Countries.search("cote d'i", "fr") == [{"Côte d'Ivoire", "CI"}]
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

  describe "French" do
    test "names the countries in French" do
      assert Countries.name("DE", "fr") == "Allemagne"
      assert Countries.name("US", "fr") == "États-Unis"
      assert Countries.name("GB", "fr") == "Royaume-Uni"
      assert Countries.name("ZA", "fr") == "Afrique du Sud"
      assert Countries.name("CH", "fr") == "Suisse"
    end

    test "names the region presets in French" do
      by_key = Map.new(Countries.regions("fr"), &{&1.key, &1.name})

      assert by_key["EU"] == "Union européenne"
      assert by_key["APAC"] == "Asie-Pacifique"
    end

    test "every country really has a French name, not the English fallback" do
      # The column was generated from the CLDR data the backend compiles in
      # rather than typed out, so what is worth asserting is that the generation
      # covered all of it. "Non-empty" would not say that: an unresolved locale
      # falls back to English, which is non-empty too, so this counts the names
      # that actually differ from their English column. Most French country
      # names do (Allemagne, Espagne, Chine); the ones that do not are the
      # genuinely identical spellings (France, Canada, Angola).
      for code <- Countries.all() do
        assert String.trim(Countries.name(code, "fr")) != "", "empty French name for #{code}"
      end

      differing =
        Enum.count(Countries.all(), &(Countries.name(&1, "fr") != Countries.name(&1, "en")))

      assert differing > 150,
             "only #{differing} French names differ from English — is the column resolving at all?"
    end

    test "sorts the select options by the French name, folding accents" do
      options = Countries.select_options("fr")

      assert length(options) == length(Countries.all())
      assert {"Allemagne", "DE"} in options

      # Folded, so "Égypte" sorts at E rather than after Z.
      names = Enum.map(options, fn {name, _code} -> name end)

      assert Enum.find_index(names, &(&1 == "Égypte")) <
               Enum.find_index(names, &(&1 == "Espagne"))
    end
  end
end
