defmodule Vutuv.ColognePhoneticsTest do
  use ExUnit.Case, async: true

  import Vutuv.WorkCounter

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

  describe "to_cologne/1 on a long word" do
    # Bounds `encode_string/5` against the quadratic append it used to do (see
    # the comment there). Calibrated on this word: 9_596_862 reductions with the
    # append, 336_584 without — with the input cap now in front of it, an
    # over-long word costs even less. An order of magnitude of headroom each way.
    test "stays linear in the length of the word" do
      word = String.duplicate("a", 20_000)

      {work, encoded} = count_reductions(fn -> ColognePhonetics.to_cologne(word) end)

      assert encoded == "0"
      assert work < 1_000_000
    end

    # The encoder takes a name, and both callers can be handed more than a name
    # by a stranger — the public search box, and a sign-up's raw `first_name`,
    # which reaches `Vutuv.Accounts.SearchTerm` before any length validation.
    test "cuts the word to 100 characters before encoding" do
      assert ColognePhonetics.to_cologne(String.duplicate("ab", 500)) ==
               ColognePhonetics.to_cologne(String.duplicate("ab", 50))
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
