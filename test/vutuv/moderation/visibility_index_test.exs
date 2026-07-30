defmodule Vutuv.Moderation.VisibilityIndexTest do
  @moduledoc """
  Guards `users_visible_covering_index` (migrations
  `20260725170422_add_users_visibility_partial_index` +
  `20260730153109_cover_visible_users_index`) against drift.

  The partial index spells the public-visibility gate a second time, in SQL,
  so Postgres can serve the ~55 query sites that filter on
  `account_confirmed_row(u) and not account_hidden_row(u)` from an index
  instead of reading all 60k users rows. Postgres only uses a partial index
  when it can *prove* the query's WHERE implies the index predicate — and it
  proves nothing loudly: if the two ever drift apart, every gated query
  quietly falls back to a sequential scan and only a profiler notices.

  So this asserts the implication itself rather than any timing: with
  sequential scans disabled, a query built from the two macros must still be
  planned onto the index. Change the gate and this fails until the migration's
  predicate follows.
  """

  use Vutuv.DataCase, async: true

  import Vutuv.Moderation.Query, only: [account_confirmed_row: 1, account_hidden_row: 1]

  alias Vutuv.Accounts.User

  @index "users_visible_covering_index"

  test "the visibility gate is still covered by #{@index}" do
    query = from(u in User, where: account_confirmed_row(u) and not account_hidden_row(u))

    assert plan_for(query) =~ @index,
           """
           The public-visibility gate is no longer served by #{@index}.

           `account_confirmed_row/1` / `account_hidden_row/1` in
           Vutuv.Moderation.Query changed so that Postgres can no longer prove
           the query predicate implies the index predicate, so every gated
           query (search, the follow lists, the tag pages, the directory) is
           back to a full scan of users.

           Fix: add a migration that recreates #{@index} with a predicate
           matching the new gate. Remember `now()` and friends cannot appear in
           an index predicate — leave time-dependent arms (the suspension
           window) out, they only narrow the query and the proof still holds.

           Plan was:
           #{plan_for(query)}
           """
  end

  # The planner would rather scan a small test table than use any index, so
  # sequential scans are ruled out first: what is left tells us whether the
  # index is *usable*, which is the property under test. SET LOCAL keeps it
  # inside the sandbox transaction.
  defp plan_for(query) do
    Repo.query!("SET LOCAL enable_seqscan = off")
    {sql, params} = Repo.to_sql(:all, query)

    Repo.query!("EXPLAIN " <> sql, params).rows
    |> Enum.map_join("\n", &hd/1)
  end
end
