defmodule Vutuv.Repo.Migrations.DropSearchHistoryTables do
  use Ecto.Migration

  # The contract half of the expand/contract pair that removed the search
  # history. v7.306.0 deleted every reader and writer — `Search.record_query/2`,
  # the phonetic matcher that existed only to fill the result table, the
  # `HistorySweeper` and the three schemas — so the release now serving traffic
  # does not touch these tables and this drop is N-1 safe.
  #
  # They were written on every settled search and read by no feature: the query
  # string, the members it matched, and one row per search naming who ran it,
  # kept for 90 days. The privacy policy justified that with a search the rows
  # would "improve and speed up", which was never built; it now says the query
  # is answered and discarded (edited at /admin/legal on 2026-08-17).

  def up do
    # Children before the parent: both carry an FK to search_queries.
    drop(table(:search_query_results))
    drop(table(:search_query_requesters))
    drop(table(:search_queries))
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "irreversible: the search history was removed on purpose (v7.306.0), " <>
          "and the rows it held are not worth restoring"
  end
end
