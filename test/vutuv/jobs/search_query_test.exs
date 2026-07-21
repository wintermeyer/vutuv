defmodule Vutuv.Jobs.SearchQueryTest do
  @moduledoc """
  The `/jobs` board search-box grammar (issue #952): comma/`or` → OR between
  titles, `*` prefix wildcard, `"…"` phrase, `-` exclusion, and the safety
  guarantee that no visitor input can produce a `to_tsquery` string that raises.
  """

  use ExUnit.Case, async: true

  alias Vutuv.Jobs.SearchQuery

  describe "single term" do
    test "one word is a plain lexeme" do
      assert SearchQuery.to_tsquery("Elixir") == "elixir"
    end

    test "several words are AND-ed" do
      assert SearchQuery.to_tsquery("Senior Elixir Engineer") ==
               "(senior & elixir & engineer)"
    end

    test "a hyphenated word splits into AND-ed lexemes" do
      assert SearchQuery.to_tsquery("PHP-Entwickler") == "(php & entwickler)"
    end
  end

  describe "comma / or → OR between titles" do
    test "comma separates OR-groups" do
      assert SearchQuery.to_tsquery("Webentwickler, PHP-Entwickler") ==
               "(webentwickler | (php & entwickler))"
    end

    test "the word 'or' separates OR-groups" do
      assert SearchQuery.to_tsquery("web developer or php developer") ==
               "((web & developer) | (php & developer))"
    end

    test "the German 'oder' separates OR-groups" do
      assert SearchQuery.to_tsquery("Entwickler oder Ingenieur") ==
               "(entwickler | ingenieur)"
    end

    test "a pipe separates OR-groups" do
      assert SearchQuery.to_tsquery("java|kotlin") == "(java | kotlin)"
    end

    test "'or' inside a word is not a separator" do
      assert SearchQuery.to_tsquery("editor") == "editor"
      assert SearchQuery.to_tsquery("corridor") == "corridor"
    end

    test "newlines separate OR-groups (a pasted list)" do
      assert SearchQuery.to_tsquery("Webentwickler\nPHP Developer") ==
               "(webentwickler | (php & developer))"
    end
  end

  describe "prefix wildcard" do
    test "a trailing * becomes a prefix match" do
      assert SearchQuery.to_tsquery("entwickl*") == "entwickl:*"
    end

    test "the wildcard applies to the last lexeme of a word" do
      assert SearchQuery.to_tsquery("full-stack*") == "(full & stack:*)"
    end

    test "wildcards combine with OR" do
      assert SearchQuery.to_tsquery("entwickl*, develop*") ==
               "(entwickl:* | develop:*)"
    end
  end

  describe "quoted phrase" do
    test "quoted words become an adjacent phrase" do
      assert SearchQuery.to_tsquery(~s("Full Stack Developer")) ==
               "(full <-> stack <-> developer)"
    end

    test "a comma inside a phrase does not split it" do
      assert SearchQuery.to_tsquery(~s("Berlin, Germany")) ==
               "(berlin <-> germany)"
    end

    test "a phrase OR-ed with a plain title" do
      assert SearchQuery.to_tsquery(~s(Elixir, "Ruby on Rails")) ==
               "(elixir | (ruby <-> on <-> rails))"
    end
  end

  describe "exclusion" do
    test "a leading - excludes the word from the whole search" do
      assert SearchQuery.to_tsquery("entwickler -praktikum") ==
               "entwickler & !(praktikum)"
    end

    test "exclusion applies across OR-groups globally" do
      assert SearchQuery.to_tsquery("entwickler, developer -senior") ==
               "(entwickler | developer) & !(senior)"
    end

    test "an excluded prefix wildcard" do
      assert SearchQuery.to_tsquery("developer -intern*") ==
               "developer & !(intern:*)"
    end
  end

  describe "empty / junk input never raises and yields nil" do
    test "blank and non-binary" do
      assert SearchQuery.to_tsquery("") == nil
      assert SearchQuery.to_tsquery("   ") == nil
      assert SearchQuery.to_tsquery(nil) == nil
    end

    test "punctuation-only input collapses to nil" do
      assert SearchQuery.to_tsquery(",,,") == nil
      assert SearchQuery.to_tsquery("* - ! |") == nil
      assert SearchQuery.to_tsquery(~s("")) == nil
    end

    test "tsquery operator characters are neutralised, not passed through" do
      # Would be a syntax error if handed raw to to_tsquery/2.
      assert SearchQuery.to_tsquery("(a & b) : c") == "(a & b & c)"
      assert SearchQuery.to_tsquery("c++") == "c"
    end
  end
end
