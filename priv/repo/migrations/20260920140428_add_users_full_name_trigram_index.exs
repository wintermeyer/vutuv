defmodule Vutuv.Repo.Migrations.AddUsersFullNameTrigramIndex do
  @moduledoc """
  The fourth trigram index the person search needs, and the one that makes the
  other three usable.

  `Vutuv.SearchText.name_ilike/3` matches a name three ways — `first_name`,
  `last_name`, and the two joined by a space, so that "Jan Petersen" finds a
  row neither column holds on its own. The first two have had trigram indexes
  since `20260828083124`; the concat has none, because it is an expression and
  no column index covers it. **One unindexable arm in an OR chain takes the
  whole BitmapOr down with it**, so every one of those three indexes sat unused
  and `Accounts.search_people/3` planned a sequential scan over `users` on
  every debounced keystroke.

  Measured with the real query shape: 4.79 ms to 0.41 ms over the 6,051 rows of
  a production copy, and 63.8 ms to 0.45 ms over a 102,867-row build of the
  same data — the point being that the old plan grows with the table and the
  new one does not.

  **The expression must mirror `name_ilike/3` character for character** or the
  planner silently never uses this index and nothing anywhere reports it. It is
  the left-associative two-step `first_name || ' ' || last_name` that Ecto
  emits; `concat(first_name, ' ', last_name)` and any `coalesce` wrapper
  normalize differently and would not match.
  `test/vutuv/search_people_index_test.exs` pins the pair.

  Two limits worth knowing rather than discovering. A row with a NULL
  `first_name` or `last_name` has a NULL concat, so it is absent from this
  index — it is still found through the column arms, and the answer is
  unchanged either way. And pg_trgm needs three characters to form a trigram,
  so a two-character term still plans a sequential scan however many indexes
  stand here; the sibling migration records the same limit.

  Built CONCURRENTLY, so this migration may run neither in a transaction nor
  behind the migrator's advisory lock. A plain addition, so it is N-1
  compatible and ships in one deploy.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name "users_full_name_trgm_index"
  # Written out rather than built with `index/3`'s column list, which quotes
  # what it is given and would index a column of that name instead.
  @expression ~s{(first_name || ' ' || last_name) gin_trgm_ops}

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name} ON users USING gin (#{@expression})"
    )
  end

  # pg_trgm stays: the sibling name indexes, `search_terms` and the tags all
  # need it.
  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index_name}")
  end
end
