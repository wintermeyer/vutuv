defmodule Vutuv.Repo.Migrations.AddCvSearchTrigramIndexes do
  use Ecto.Migration

  # The member directory's search box gained two CV fields — "Firma" and
  # "Schule & Uni" — and both are the same query shape the name fields already
  # taught this repo twice: `ILIKE '%needle%'`, which no btree index can serve
  # because of the leading wildcard. Without these, every debounced keystroke
  # sequentially scans `work_experiences` and `educations` (and `organizations`
  # through the link join), on top of the `users` scan that
  # `20260828083124_add_users_name_trigram_indexes` already fixed.
  #
  # `organizations.name` is here because a work experience may link a verified
  # organization page, and the search matches that name too: a member who wrote
  # "DB" and linked "Deutsche Bahn AG" is otherwise unfindable under the name
  # the page carries. That one is the forward-looking member of the three: on a
  # 5,000-page copy the planner still prefers a sequential scan (3.68 ms against
  # the index's 3.65 ms) and switches over as the table grows. It earns its
  # write cost cheaply — organization names are renamed far more rarely than
  # members edit their CV.
  #
  # All three only pay off because `Directory.field_match/2` builds each word's
  # match set as a UNION of one-table queries: inside a single OR that spans
  # tables, Postgres uses none of them (measured 54.8 ms against 0.645 ms).
  #
  # Three characters stays the minimum (`Vutuv.Directory.min_query_chars/0`):
  # pg_trgm needs three to form a trigram, so a shorter needle plans a
  # sequential scan however many indexes stand here.
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
