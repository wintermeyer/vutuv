defmodule Vutuv.SocialFeed.PostTruncateTest do
  @moduledoc """
  The clamp of the remote-content stack (issue #1741).

  Its own file, and `async: true`, because it is a pure string function that
  four modules across two subsystems share — a remote post's body
  (`Vutuv.Mastodon`, `Vutuv.Bluesky`), the reduced text of a stranger's HTML
  (`Vutuv.RemoteHtml`) and a repository description
  (`Vutuv.CodeStats.Snapshot`). It had no test of its own, and what it promises
  is worth stating in one place rather than inferring from whichever caller you
  happen to be reading.
  """
  use ExUnit.Case, async: true

  alias Vutuv.SocialFeed.Post

  test "text within the budget is returned untouched" do
    assert Post.truncate("kurz", 10) == "kurz"
    # Exactly at the cap is not over it.
    assert Post.truncate("1234567890", 10) == "1234567890"
  end

  test "the cut lands between words, not inside one" do
    assert Post.truncate("Fahrradweg am Fluss entlang", 24) == "Fahrradweg am Fluss…"
  end

  test "the last run of non-space goes even when it happened to fit exactly" do
    # `\s+\S*$` does not ask whether the word it strips was complete, so a cut
    # landing exactly on a word boundary still drops that word. Kept
    # deliberately: the alternative is peeking at the character past the budget
    # to tell "ended cleanly" from "cut mid-word", and one spare word costs less
    # than a rule with two branches. Recorded here so the next reader knows it
    # was a choice.
    assert Post.truncate("Fahrradweg am Fluss entlang", 20) == "Fahrradweg am…"
  end

  test "the result never exceeds the budget" do
    long = String.duplicate("wort ", 100)

    # No 500: the fixture is exactly 500 characters, so that iteration never
    # enters the truncating branch and only restates the first test.
    for max <- [5, 12, 40, 160] do
      assert String.length(Post.truncate(long, max)) <= max
    end
  end

  test "a first word longer than the whole budget keeps the blunt cut" do
    # There is no space to cut at, and a clamp that answered "…" would be worse
    # than a clamp that answers as much of the word as fits.
    assert Post.truncate("Donaudampfschifffahrtsgesellschaft", 10) == "Donaudamp…"
  end

  test "leading whitespace cannot eat the whole answer" do
    # `\\s+\\S*$` matches the entire slice when the budget reaches no further
    # than the first word, which would otherwise leave a bare ellipsis.
    assert Post.truncate("   Fahrradweg am Fluss", 8) == "   Fahr…"
  end

  test "the default cap is the shared remote-post one" do
    long = String.duplicate("a", 600)

    assert String.length(Post.truncate(long)) <= 500
    assert String.ends_with?(Post.truncate(long), "…")
  end
end
