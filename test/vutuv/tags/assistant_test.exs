defmodule Vutuv.Tags.AssistantTest do
  @moduledoc """
  The assisted pass (issue #1338). It proposes, a human decides, and the pairs
  it may propose are bounded by rule rather than by prompt — which is what this
  file guards.

  `async: false` because the judging half is switched by `:tag_merge_assist`, an
  application env every other test in the run would see (see the test guidelines).
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Tags.Assistant
  alias Vutuv.Tags.Merge
  alias Vutuv.Tags.MergeCandidate
  alias Vutuv.Tags.Tag

  setup do
    original = Application.fetch_env(:vutuv, :tag_merge_assist)
    Application.put_env(:vutuv, :tag_merge_assist, false)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :tag_merge_assist, was)
        :error -> Application.delete_env(:vutuv, :tag_merge_assist)
      end
    end)

    :ok
  end

  defp tag(name) do
    insert(:tag, name: name, slug: Vutuv.SlugHelpers.gen_tag_slug_unique(name, Tag, :slug))
  end

  defp entry(name), do: %{id: Vutuv.UUIDv7.generate(), name: name}

  defp generated(names) do
    names
    |> Enum.map(&entry/1)
    |> Assistant.generate()
    |> Enum.map(fn {a, b, rule} -> {Enum.sort([a.name, b.name]), rule} end)
    |> Enum.sort()
  end

  describe "the deterministic generators" do
    test "same_key: the names agree once case and separators are folded away" do
      assert {["Ruby on Rails", "rubyonrails"], "same_key"} in generated([
               "Ruby on Rails",
               "rubyonrails"
             ])

      assert {["Open-Source", "open source"], "same_key"} in generated([
               "open source",
               "Open-Source"
             ])
    end

    test "acronym: a multi-word name's initials are another tag's whole name" do
      assert {["ROR", "Ruby on Rails"], "acronym"} in generated(["Ruby on Rails", "ROR"])

      assert {["CRM", "Customer Relationship Management"], "acronym"} in generated([
               "Customer Relationship Management",
               "CRM"
             ])
    end

    test "token: a short name is one whole word of a longer one" do
      pairs = generated(["Ruby on Rails", "rails", "Ruby"])

      # Both are generated, and that is the point: one of them is a merge and
      # the other never is. Telling them apart is the judge's job, not the
      # generator's.
      assert {["Ruby on Rails", "rails"], "token"} in pairs
      assert {["Ruby", "Ruby on Rails"], "token"} in pairs
    end

    test "a two-letter word is not a token candidate" do
      # Otherwise "on" would pair "Ruby on Rails" with every tag called "on".
      assert generated(["Ruby on Rails", "on"]) == []
    end

    test "no edit distance: a typo is not a candidate" do
      # Typos are out of scope (#1338), so a one-character difference produces
      # nothing at all.
      assert generated(["Ruby on Rails", "Ryby on Rails"]) == []
    end

    test "the punctuation bucket is never even generated" do
      # `c`, `c++` and `c#` fold to different keys, so no rule pairs them.
      assert generated(["c", "c++", "c#", "µc"]) == []
    end
  end

  describe "scan/1" do
    test "writes one queue row per pair, ranked by the members it would touch" do
      big_a = tag("Ruby on Rails")
      big_b = tag("rubyonrails")
      small_a = tag("Elixir Language")
      small_b = tag("elixirlanguage")

      for _ <- 1..3, do: insert(:user_tag, user: insert(:activated_user), tag: big_a)
      insert(:user_tag, user: insert(:activated_user), tag: small_a)

      report = Assistant.scan(judge: false)

      assert report.written == 2

      assert [first, second] = Assistant.queue()
      assert Enum.sort([first.tag_a_id, first.tag_b_id]) == Enum.sort([big_a.id, big_b.id])
      assert Enum.sort([second.tag_a_id, second.tag_b_id]) == Enum.sort([small_a.id, small_b.id])
      assert first.members_affected == 3
    end

    test "an unjudged shares-a-word pair is not put in the queue" do
      # Measured against the real catalog, this rule is four fifths of
      # everything the generators find and almost none of it is a merge
      # ("embedded linux" is not "Linux"). Without a verdict it is a chore, not
      # a proposal.
      tag("Ruby on Rails")
      tag("rails")

      assert Assistant.scan(judge: false).written == 0
      assert Assistant.queue() == []
    end

    test "the obvious pairs are ranked above the ones that merely share a word" do
      # Ordering by members alone puts the worst rows on top, because the
      # biggest tag is the one every specialization shares a word with.
      big = tag("Linux")
      for _ <- 1..5, do: insert(:user_tag, user: insert(:activated_user), tag: big)
      tag("embedded Linux")

      small = tag("java script")
      insert(:user_tag, user: insert(:activated_user), tag: small)
      tag("javascript")

      report = Assistant.scan(judge: false)

      # The shares-a-word pair is generated and counted, but the queue leads
      # with the two spellings of one string.
      assert report.generated == 2
      assert [candidate] = Assistant.queue()
      assert candidate.generator == "same_key"
    end

    test "a pair the merge would refuse never reaches the queue" do
      # The guardrail is applied to the candidate, not left to the model: the
      # generator would not produce this pair anyway, and a pair already called
      # distinct is refused here too.
      a = tag("Ruby on Rails")
      b = tag("rubyonrails")
      {:ok, _} = Merge.mark_distinct(a, b)

      assert Assistant.scan(judge: false).written == 0
      assert Assistant.queue() == []
    end

    test "an honor tag is left out of the catalog entirely" do
      tag("Ruby on Rails") |> Ecto.Changeset.change(honor?: true) |> Repo.update!()
      tag("rubyonrails")

      assert Assistant.scan(judge: false).written == 0
    end

    test "an alternative name is not proposed again" do
      canonical = tag("Ruby on Rails")
      absorbed = tag("rubyonrails")
      {:ok, _} = Merge.merge(absorbed, canonical)

      assert Assistant.scan(judge: false).written == 0
    end

    test "running it twice leaves one row per pair" do
      tag("Ruby on Rails")
      tag("rubyonrails")

      Assistant.scan(judge: false)
      Assistant.scan(judge: false)

      assert Repo.aggregate(MergeCandidate, :count) == 1
    end

    test "a second run spends its budget on pairs that are not queued yet" do
      # Otherwise the cap would hand back the same top rows every time and the
      # long tail would be unreachable, however often an admin scanned.
      tag("java script")
      tag("javascript")
      tag("Ruby on Rails")
      tag("rubyonrails")

      first = Assistant.scan(judge: false, cap: 1)
      assert first.written == 1
      assert first.dropped == 1

      second = Assistant.scan(judge: false, cap: 1)
      assert second.written == 1
      assert second.dropped == 0

      assert Repo.aggregate(MergeCandidate, :count) == 2
    end

    test "with the model off the queue still fills, unjudged" do
      # The air-gapped case: proposals a human reads, no verdict attached.
      tag("Ruby on Rails")
      tag("rubyonrails")

      report = Assistant.scan()

      assert report.written == 1
      assert report.judged == 0
      assert [candidate] = Assistant.queue()
      assert is_nil(candidate.judged_at)
      assert is_nil(candidate.suggested_canonical_id)
    end

    test "the cap reports what it dropped rather than trimming silently" do
      tag("Ruby on Rails")
      tag("rubyonrails")
      tag("Elixir Language")
      tag("elixirlanguage")

      report = Assistant.scan(judge: false, cap: 1)

      # A queue that quietly stops at its cap reads as "that was everything".
      assert report.written == 1
      assert report.dropped == 1
      assert Repo.aggregate(MergeCandidate, :count) == 1
    end
  end

  describe "judge/3" do
    test "answers nothing while the model is switched off" do
      assert is_nil(Assistant.judge(entry("Ruby on Rails"), entry("ROR"), "acronym"))
    end
  end
end
