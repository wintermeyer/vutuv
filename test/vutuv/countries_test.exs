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
      keys = Enum.map(options, fn {name, _code} -> fold(name) end)
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

  describe "all/0" do
    test "covers the full ISO 3166-1 alpha-2 set" do
      codes = Countries.all()
      assert length(codes) >= 240
      assert "DE" in codes
      assert Enum.all?(codes, &(&1 == String.upcase(&1)))
    end
  end

  # Mirror of the module's private sort key, so the sort assertion checks the
  # same folded ordering the module produces.
  defp fold(name) do
    name
    |> String.downcase()
    |> String.replace("ä", "a")
    |> String.replace("ö", "o")
    |> String.replace("ü", "u")
    |> String.replace("ß", "ss")
    |> String.replace("å", "a")
    |> String.replace("á", "a")
    |> String.replace("à", "a")
    |> String.replace("é", "e")
    |> String.replace("è", "e")
    |> String.replace("ç", "c")
    |> String.replace("í", "i")
    |> String.replace("ó", "o")
    |> String.replace("ú", "u")
  end
end
