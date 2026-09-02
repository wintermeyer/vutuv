defmodule Vutuv.ContentFilterWildcardsTest do
  @moduledoc """
  How many `*` one mute rule may name, and why the number is small.

  Each `*` becomes a `.*`, and the 100-character cap alone left room for about
  fifty of them. In the whole-word shape — which every **tag** rule uses
  (`compile_pattern(normalized, true)`) — the `\\b` at each end takes away
  PCRE's required-literal shortcut, and `\\ba.*a.*a…a\\b` against a long run of
  the same letter backtracks hard. Measured on a 3,000-character subject that
  does **not** match: 5 wildcards cost 767 reductions, 15 cost 13,042, and 30
  cost 1,875,753 — and that is per post in the feed, and again on every
  keystroke of the filter band's live preview.

  So the rule never becomes a regex at all past the cap, and the changeset says
  so rather than leaving the member a rule that quietly matches nothing.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.WorkCounter

  alias Vutuv.ContentFilters
  alias Vutuv.ContentFilters.ContentFilter
  alias Vutuv.Posts.Post

  defp tag_rule(pattern) do
    %ContentFilter{kind: :tag, pattern: pattern, whole_word: true}
  end

  defp keyword_rule(pattern) do
    %ContentFilter{kind: :keyword, pattern: pattern, whole_word: true, account: "*"}
  end

  describe "the cap" do
    test "a rule inside it compiles" do
      assert %{tags: [_]} = ContentFilters.compile([tag_rule("Arbeits*zeugnis*")])
    end

    test "a rule past it never becomes a regex" do
      hostile = String.duplicate("a*", 30) <> "a"

      assert %{tags: [], keywords: []} = ContentFilters.compile([tag_rule(hostile)])
    end

    # The bound that matters, measured on the path the feed really walks:
    # 1,667,110 reductions per post with the rule compiled, a few hundred with
    # it refused. An order of magnitude of headroom either way.
    test "a hostile rule costs the feed nothing per post" do
      hostile = String.duplicate("a*", 30) <> "a"
      # A whole-word KEYWORD rule, because that is the one matched against the
      # post's body — a tag rule only ever sees the tag names, so it would not
      # run this regex over 3,000 characters and the bound would prove nothing.
      compiled = ContentFilters.compile([keyword_rule(hostile)])
      post = %Post{body: String.duplicate("a", 3_000) <> " ", tags: []}

      {work, result} = count_reductions(fn -> ContentFilters.filtered(post, compiled) end)

      assert result == nil
      assert work < 100_000
    end
  end

  describe "the changeset" do
    test "refuses a pattern past the cap, naming the limit" do
      changeset =
        ContentFilter.changeset(%ContentFilter{}, %{
          "kind" => "keyword",
          "pattern" => String.duplicate("a*", 30) <> "a"
        })

      refute changeset.valid?
      assert %{pattern: [message]} = errors_on(changeset)
      assert message =~ "at most"
    end

    test "refuses an account scope past the cap too" do
      changeset =
        ContentFilter.changeset(%ContentFilter{}, %{
          "kind" => "keyword",
          "pattern" => "crypto",
          "account" => String.duplicate("a*", 30) <> "a"
        })

      refute changeset.valid?
      assert %{account: [_]} = errors_on(changeset)
    end

    test "leaves an ordinary rule alone" do
      changeset =
        ContentFilter.changeset(%ContentFilter{}, %{
          "kind" => "keyword",
          "pattern" => "Arbeits*zeugnis",
          "account" => "*@social.heise.de"
        })

      assert changeset.valid?
    end
  end
end
