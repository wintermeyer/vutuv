defmodule Vutuv.Repo.FeedIndexesTest do
  @moduledoc """
  The two indexes the newsfeed's main query needs, pinned so a later migration
  cannot quietly drop them.

  Neither changes a result, so nothing else in the suite would go red if they
  disappeared — the page would simply get slower and slower as the tables grow,
  which is the kind of regression nobody notices for months.

  Measured on a copy of production seeded to 200,000 posts, the feed's
  "posts of me and the people I follow" query went from **76.7 ms to 0.53 ms**
  with these two in place. Without them Postgres reads the whole posts table
  and top-N sorts it on every feed load (at 200k rows: 84,513 candidates
  matched, 115,487 discarded), and re-derives the set of moderation-hidden
  accounts by scanning all of `users` once per post query — five times on one
  `/feed`.
  """
  use Vutuv.DataCase, async: true

  describe "posts_recency_index" do
    test "covers the feed's sort key" do
      assert index_definition("posts", "posts_recency_index") =~ "inserted_at DESC"
      assert index_definition("posts", "posts_recency_index") =~ "id DESC"
    end
  end

  describe "users_hidden_index" do
    test "covers exactly the four columns that hide an account" do
      definition = index_definition("users", "users_hidden_index")

      for column <- ~w(frozen_at deactivated_at unreachable_at suspended_until) do
        assert definition =~ column,
               "#{column} hides an account (Vutuv.Moderation.Query.account_hidden/1) " <>
                 "but is missing from the partial index that finds them"
      end
    end

    test "is a partial index, not a full one" do
      # The point is its size: a few hundred hidden accounts instead of every
      # member. A full index on the same columns would be no cheaper to scan
      # than the table.
      assert index_definition("users", "users_hidden_index") =~ "WHERE"
    end

    test "keeps its predicate immutable, so Postgres may use it" do
      # `suspended_until > now()` cannot live in an index predicate (now() is
      # not immutable) — the index has to say IS NOT NULL and leave the
      # comparison to the query, on the handful of rows it returns.
      definition = index_definition("users", "users_hidden_index")

      refute definition =~ "now()",
             "an index predicate with now() in it is not immutable and Postgres will refuse it"
    end
  end

  defp index_definition(table, name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' " <>
          "AND tablename = $1 AND indexname = $2",
        [table, name]
      )

    case rows do
      [[definition]] -> definition
      [] -> flunk("#{table} has no index named #{name}")
    end
  end
end
