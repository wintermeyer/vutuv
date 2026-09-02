defmodule Vutuv.SoundexTest do
  @moduledoc """
  The Soundex half of name search. `Vutuv.Search` runs both encoders over every
  free-text query section, and `Vutuv.Accounts.SearchTerm` runs them over stored
  names, so the two have to agree on a word forever: a change in either one
  makes every stored term unfindable until they are regenerated.

  The reference encodings below are that pin. The work bound is the other half —
  see the comment on it.
  """
  use ExUnit.Case, async: true

  import Vutuv.WorkCounter

  alias Vutuv.Soundex

  describe "to_soundex/1" do
    test "returns \"\" for an empty string and nil for nil" do
      assert Soundex.to_soundex("") == ""
      assert Soundex.to_soundex(nil) == nil
    end

    # The canonical Soundex examples, and what this implementation makes of
    # them today. They are here to catch an encoding change, not to bless one
    # reading of the algorithm.
    test "encodes the reference words" do
      assert Soundex.to_soundex("Robert") == "R163"
      assert Soundex.to_soundex("Rupert") == "R163"
      assert Soundex.to_soundex("Ashcraft") == "A261"
      assert Soundex.to_soundex("Tymczak") == "T522"
      assert Soundex.to_soundex("Pfister") == "P236"
      assert Soundex.to_soundex("Honeyman") == "H555"
    end

    test "pads and truncates to four characters" do
      assert Soundex.to_soundex("Meyer") == "M600"
      assert Soundex.to_soundex("Wikipedia") == "W213"
    end
  end

  describe "to_soundex/1 on a long word" do
    # Same defect and same fix as `Vutuv.ColognePhonetics` — see the comment on
    # `encode_list/2`. Calibrated on this word: 9_657_196 reductions with the
    # append, 304_353 without.
    test "stays linear in the length of the word" do
      word = String.duplicate("a", 20_000)

      {work, encoded} = count_reductions(fn -> Soundex.to_soundex(word) end)

      assert encoded == "A000"
      assert work < 1_000_000
    end

    test "cuts the word to 100 characters before encoding" do
      assert Soundex.to_soundex(String.duplicate("ab", 500)) ==
               Soundex.to_soundex(String.duplicate("ab", 50))
    end
  end
end
