defmodule Vutuv.SearchTextTest do
  @moduledoc """
  The two halves of `Vutuv.SearchText` that are easy to confuse.

  `cap/1` bounds a query box. `normalize_search/1` only trims — despite its name
  it is the tree's general "trim, blank to nil" helper, and `Vutuv.Fediverse`
  runs remote URIs through it. Putting the cap inside it once shortened a 2 KB
  quote URI to 200 characters and slipped it past the length check meant to drop
  it, so the last test here holds those two apart.
  """
  use ExUnit.Case, async: true

  alias Vutuv.SearchText

  describe "cap/1" do
    test "cuts to max_chars/0 and leaves anything shorter alone" do
      assert String.length(SearchText.cap(String.duplicate("a", 5_000))) ==
               SearchText.max_chars()

      assert SearchText.cap("müller") == "müller"
    end

    test "cuts on a character boundary, never mid-codepoint" do
      capped = SearchText.cap(String.duplicate("ä", 5_000))

      assert String.valid?(capped)
      assert String.length(capped) == SearchText.max_chars()
    end

    test "passes a non-binary through untouched" do
      assert SearchText.cap(nil) == nil
    end
  end

  describe "normalize_search/1" do
    test "trims, and collapses blank or non-binary to nil" do
      assert SearchText.normalize_search("  meier ") == "meier"
      assert SearchText.normalize_search("   ") == nil
      assert SearchText.normalize_search(nil) == nil
    end

    # The regression: capping here truncates the remote URIs and report reasons
    # that also pass through, which hides an over-long value from the validation
    # that exists to reject it.
    test "does not cap — an over-long value comes back whole" do
      uri = "https://third.example/notes/" <> String.duplicate("a", 2_048)

      assert SearchText.normalize_search(uri) == uri
    end
  end
end
