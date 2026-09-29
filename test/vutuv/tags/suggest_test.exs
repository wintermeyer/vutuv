defmodule Vutuv.Tags.SuggestTest do
  @moduledoc """
  `Vutuv.Tags.suggest/2`: the existing topics offered under every tag field
  while a member types.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Tags

  # Every test gets a prefix no other test's tags share, so the async suite's
  # rows never show up in each other's answers.
  setup do
    %{p: "zq#{System.unique_integer([:positive])}"}
  end

  defp tag(name, members \\ 0, attrs \\ []) do
    tag = insert(:tag, [name: name, slug: Vutuv.SlugHelpers.tagify(name)] ++ attrs)
    for _ <- 1..members//1, do: insert(:user_tag, user: insert(:activated_user), tag: tag)
    tag
  end

  test "offers topics that start with what was typed, most members first", %{p: p} do
    tag("#{p}alpha", 1)
    tag("#{p}beta", 3)
    tag("other #{p}", 5)

    assert [
             %{name: name_b, count: 3, alias: nil},
             %{name: name_a, count: 1, alias: nil},
             %{name: _word_match}
           ] = Tags.suggest(p)

    assert name_b == "#{p}beta"
    assert name_a == "#{p}alpha"
  end

  test "a word inside a longer name matches after the whole-name matches", %{p: p} do
    tag("Ruby #{p}rails", 9)
    tag("#{p}ruby", 1)

    assert [%{name: first}, %{name: second}] = Tags.suggest(p)
    assert first == "#{p}ruby"
    assert second == "Ruby #{p}rails"
  end

  test "spelling differences in spaces, hyphens and case do not matter", %{p: p} do
    tag("#{p} Open Source", 2)

    assert [%{name: name}] = Tags.suggest(String.upcase(p) <> "-open-sou")
    assert name == "#{p} Open Source"
  end

  test "an alternative name offers its topic once, saying which name matched", %{p: p} do
    canonical = tag("#{p}javascript", 4)
    tag("#{p}js", 0, merged_into_id: canonical.id)

    assert [%{name: name, count: 4, alias: via}] = Tags.suggest(p)
    assert name == "#{p}javascript"
    # Matched by its own name, so nothing to explain.
    assert via == nil

    assert [%{name: ^name, alias: alias_name}] = Tags.suggest("#{p}j")
    assert alias_name == nil

    alias_name = "#{p}js"
    assert [%{name: ^name, alias: ^alias_name}] = Tags.suggest(alias_name)
  end

  test "counts only listed members, like every other member count", %{p: p} do
    t = tag("#{p}listed", 1)
    insert(:user_tag, user: insert(:user), tag: t)

    assert [%{count: 1}] = Tags.suggest(p)
  end

  test "honor tags are never offered: members cannot give them to themselves", %{p: p} do
    tag("#{p}honor", 3, honor?: true)

    assert Tags.suggest(p) == []
  end

  test "answers at most the limit", %{p: p} do
    for i <- 1..8, do: tag("#{p}#{i}")

    assert length(Tags.suggest(p)) == 6
    assert length(Tags.suggest(p, 3)) == 3
  end

  test "nothing to match on is no query at all" do
    assert Tags.suggest("") == []
    assert Tags.suggest("  - ") == []
    assert Tags.suggest(nil) == []
  end

  test "LIKE wildcards in the typed text are taken literally", %{p: p} do
    tag("#{p}abc", 1)

    assert Tags.suggest("#{p}%") == []
  end
end
