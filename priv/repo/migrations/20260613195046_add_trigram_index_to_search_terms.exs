defmodule Vutuv.Repo.Migrations.AddTrigramIndexToSearchTerms do
  use Ecto.Migration

  # CREATE INDEX CONCURRENTLY cannot run inside a transaction, and must not sit
  # behind the migrator's advisory lock either. search_terms is by far the
  # largest table (1.1M+ rows), so a plain CREATE INDEX would hold a lock that
  # blocks writes for the whole build during the blue/green deploy. Building it
  # CONCURRENTLY keeps the registration / name-change writes to search_terms
  # flowing while the index is built.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Trigram matching so the people search's leading-wildcard
    # `value LIKE '%infix%'` (Vutuv.Search) can use an index instead of
    # sequentially scanning every row. pg_trgm is a trusted extension since
    # PG13, so the application DB role may create it.
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    # The GIN trigram index turns the per-keystroke people search from a ~280ms
    # full scan of search_terms into a ~2ms bitmap index scan (measured on the
    # 1.1M-row dev set). The existing varchar_pattern_ops btree still serves the
    # exact-equality (phonetic) arms of the same OR, combined via a BitmapOr.
    create(
      index(:search_terms, ["value gin_trgm_ops"],
        using: "GIN",
        name: "search_terms_value_trgm_index",
        concurrently: true
      )
    )
  end

  def down do
    drop(
      index(:search_terms, ["value gin_trgm_ops"],
        name: "search_terms_value_trgm_index",
        concurrently: true
      )
    )

    # pg_trgm is left installed on purpose: dropping it would fail if any other
    # index came to depend on it, and an unused extension is harmless.
  end
end
