defmodule Vutuv.ColognePhoneticsTest do
  use ExUnit.Case, async: true

  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.ColognePhonetics

  describe "to_cologne/1 edge cases" do
    test "returns \"\" for an empty string" do
      assert ColognePhonetics.to_cologne("") == ""
    end

    test "returns nil for nil" do
      assert ColognePhonetics.to_cologne(nil) == nil
    end

    test "punctuation-only input encodes to \"\" without crashing" do
      assert ColognePhonetics.to_cologne("***") == ""
      assert ColognePhonetics.to_cologne("!!!") == ""
      assert ColognePhonetics.to_cologne("...") == ""
    end

    test "emoji-only input encodes to \"\" without crashing" do
      assert ColognePhonetics.to_cologne("♥") == ""
    end
  end

  describe "to_cologne/1 canonical reference words" do
    # Reference encodings from https://en.wikipedia.org/wiki/Cologne_phonetics
    test "encodes the Wikipedia reference words" do
      assert ColognePhonetics.to_cologne("Wikipedia") == "3412"
      assert ColognePhonetics.to_cologne("Meyer") == "67"
      assert ColognePhonetics.to_cologne("Breschnew") == "17863"
    end
  end

  describe "create_search_terms/1 with phonetically-empty names" do
    test "survives a punctuation-only first/last name without crashing" do
      changesets =
        SearchTerm.create_search_terms(%{
          "first_name" => "***",
          "last_name" => "!!!"
        })

      assert is_list(changesets)
      assert Enum.all?(changesets, &match?(%Ecto.Changeset{}, &1))
    end
  end
end
