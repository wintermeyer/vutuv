defmodule Vutuv.DateRegionsTest do
  @moduledoc """
  The four date shapes and the guess that picks one from a browser's
  `Accept-Language` (issue #1502). The guess is what a new account is stamped
  with and what an existing member reads until they choose, so it has to be
  right on the ordinary tags and quiet on everything else.
  """
  use ExUnit.Case, async: true

  alias Vutuv.DateRegions

  describe "patterns" do
    test "each region writes the sample date its own way" do
      assert DateRegions.example("DE") == "31.12.2026, 14:30"
      assert DateRegions.example("GB") == "31/12/2026, 14:30"
      assert DateRegions.example("US") == "12/31/2026, 2:30 PM"
      assert DateRegions.example("ISO") == "2026-12-31, 14:30"
    end

    test "the clock is 12-hour only where the shape says so" do
      assert DateRegions.clock("US") == :h12
      for key <- ~w(DE GB ISO), do: assert(DateRegions.clock(key) == :h24)
    end

    test "a retired value renders through the first region instead of raising" do
      assert DateRegions.pattern("FR", :date) == DateRegions.pattern("DE", :date)
      assert DateRegions.clock("FR") == :h24
    end

    test "the seconds pattern is the time pattern plus seconds" do
      assert Calendar.strftime(~N[2026-12-31 14:30:09], DateRegions.pattern("DE", :seconds)) ==
               "14:30:09"

      assert Calendar.strftime(~N[2026-12-31 14:30:09], DateRegions.pattern("US", :seconds)) ==
               "2:30:09 PM"
    end
  end

  describe "from_accept_language/1" do
    test "reads the region subtag" do
      assert DateRegions.from_accept_language("en-US,en;q=0.9") == "US"
      assert DateRegions.from_accept_language("en-GB,en;q=0.9") == "GB"
      assert DateRegions.from_accept_language("de-DE,de;q=0.9") == "DE"
      assert DateRegions.from_accept_language("sv-SE,sv;q=0.8") == "ISO"
    end

    # The complaint issue #1502 opens with: a bare `en` used to mean the US
    # shape for every non-German reader on the site.
    test "falls back to the language when the tag names no region" do
      assert DateRegions.from_accept_language("en") == "GB"
      assert DateRegions.from_accept_language("de") == "DE"
      assert DateRegions.from_accept_language("ja") == "ISO"
    end

    test "finds the region past a script subtag" do
      assert DateRegions.from_accept_language("zh-Hans-CN") == "ISO"
      assert DateRegions.from_accept_language("zh-Hant") == "ISO"
    end

    test "takes the header's own order and skips tags it has no shape for" do
      assert DateRegions.from_accept_language("xx-YY,en-US;q=0.9") == "US"
      assert DateRegions.from_accept_language(["de-AT,en-US;q=0.9"]) == "DE"
    end

    # nil is "no opinion", which lets the caller fall through to the
    # installation default rather than inventing a shape for a territory whose
    # convention we never checked.
    test "answers nil when it recognises nothing" do
      assert DateRegions.from_accept_language("xx-YY") == nil
      assert DateRegions.from_accept_language("*") == nil
      assert DateRegions.from_accept_language([]) == nil
      assert DateRegions.from_accept_language(nil) == nil
    end

    test "every answer is an offered key" do
      for header <- ["en-US", "en-GB", "de-DE", "sv-SE", "en", "de", "ja", "zh-Hans-CN"] do
        assert DateRegions.known?(DateRegions.from_accept_language(header))
      end
    end
  end
end
