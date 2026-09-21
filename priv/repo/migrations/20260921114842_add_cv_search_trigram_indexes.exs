defmodule Vutuv.Repo.Migrations.AddCvSearchTrigramIndexes do
  use Ecto.Migration

  # The search page finds people by the employers and schools on their CVs
  # (`Vutuv.Search.cv_user_ids/2`), which is `ILIKE '%needle%'` on three columns
  # no btree index can serve because of the leading wildcard. Without these,
  # every debounced keystroke sequentially scans `work_experiences` and
  # `educations`, on top of the `users` scan
  # `20260828083124_add_users_name_trigram_indexes` already fixed.
  #
  # `organizations.name` is here because a work experience may link a public
  # organization page and the search matches that name too, so a member who
  # wrote "DB" and linked "Deutsche Bahn AG" is findable under the name the page
  # carries. It is also what the organizations scope matches on.
  #
  # All three only pay off because the CV set is a UNION of one-table queries:
  # inside a single OR spanning tables Postgres uses none of them. Oliver
  # Andrich measured the shape on a 100k-member copy for PR #2217: 54.8 ms as one
  # OR, 0.645 ms as the union.
  #
  # Built CONCURRENTLY, so this migration may run neither in a transaction nor
  # behind the migrator's advisory lock. Additive and N-1 compatible: it only
  # speeds up queries, so the release still serving traffic keeps working.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @columns [
    {:work_experiences, "organization"},
    {:educations, "school"},
    {:organizations, "name"}
  ]

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    for {table, column} <- @columns do
      create_if_not_exists(
        index(table, ["#{column} gin_trgm_ops"],
          using: :gin,
          name: "#{table}_#{column}_trgm_index",
          concurrently: true
        )
      )
    end
  end

  def down do
    for {table, column} <- @columns do
      drop_if_exists(
        index(table, ["#{column} gin_trgm_ops"],
          name: "#{table}_#{column}_trgm_index",
          concurrently: true
        )
      )
    end

    # pg_trgm stays installed: the users, search_terms and tags trigram indexes
    # need it.
  end
end
