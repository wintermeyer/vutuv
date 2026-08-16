defmodule Vutuv.Tags.MatchKeyIndexTest do
  @moduledoc """
  The match-key lookup must stay indexable.

  `Vutuv.Tags.MatchKey.sql/1` folds two columns through four functions, so no
  ordinary index covers it and the catalog is scanned end to end unless the
  expression indexes from `20260816221319_index_tags_on_match_key.exs` match it
  character for character. Nothing about that failure is visible — the answers
  stay right and every tag lookup silently costs a sequential scan again, which
  is what shipped between #1332 and this test.

  Postgres matches an expression index by the parsed expression, so the check is
  the planner's own: with the sequential scan priced out of reach it will use
  the index if and only if the two expressions agree.
  """
  use Vutuv.DataCase, async: true

  import Ecto.Query

  alias Vutuv.Repo
  alias Vutuv.Tags.MatchKey
  alias Vutuv.Tags.Tag

  require MatchKey

  test "the tag lookup by match key can use both expression indexes" do
    Repo.query!("SET LOCAL enable_seqscan = off")

    plan = explain(from(t in Tag, where: MatchKey.sql(t.name) == ^"elixir", select: t.id))
    assert plan =~ "tags_name_match_key_index"

    plan = explain(from(t in Tag, where: MatchKey.sql(t.slug) == ^"elixir", select: t.id))
    assert plan =~ "tags_slug_match_key_index"
  end

  test "the batched lookup can use them too" do
    Repo.query!("SET LOCAL enable_seqscan = off")

    keys = ["elixir", "postgresql"]

    plan =
      explain(
        from(t in Tag,
          where: MatchKey.sql(t.name) in ^keys or MatchKey.sql(t.slug) in ^keys,
          select: t.id
        )
      )

    assert plan =~ "tags_name_match_key_index"
    assert plan =~ "tags_slug_match_key_index"
  end

  defp explain(query), do: Repo.explain(:all, query)
end
