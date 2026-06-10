defmodule Vutuv.Repo.Migrations.AddMissingHotPathIndexes do
  use Ecto.Migration

  # Indexes the 2026 index audit found missing for queries the app actually
  # runs. Sizes from the production-shaped dev DB.
  #
  # * search_terms (1.1M rows) had ONLY its primary key:
  #   - every search runs `value LIKE 'foo%' OR value = '<phonetic>'`
  #     (Vutuv.Search.search/2) - a full-table scan per search. The
  #     varchar_pattern_ops btree serves both the LIKE prefix and equality.
  #   - every name edit replaces the user's terms (`on_replace: :delete`,
  #     `DELETE .. WHERE user_id = ?`), and user deletion cascades - both
  #     full-table scans without the user_id index. The per-user index also
  #     serves the /:slug/search_terms page.
  # * search_query_results (457K) / search_query_requesters (77K) had no FK
  #   indexes: the /search/:id page preloads by search_query_id and user
  #   deletion cascades by user_id.
  # * The profile-section tables are loaded by user_id on every profile view
  #   (and purged by user_id on account deletion) but had no user_id index:
  #   urls, addresses, phone_numbers, work_experiences, social_media_accounts.
  # * posts.ex lookup_tag/1 resolves tags by `lower(name)` (or slug; slug is
  #   already indexed) - the expression index covers the name half.
  def change do
    create(index(:search_terms, [:user_id]))

    execute(
      "CREATE INDEX search_terms_value_pattern_index ON search_terms (value varchar_pattern_ops)",
      "DROP INDEX search_terms_value_pattern_index"
    )

    create(index(:search_query_results, [:search_query_id]))
    create(index(:search_query_results, [:user_id]))
    create(index(:search_query_requesters, [:search_query_id]))
    create(index(:search_query_requesters, [:user_id]))

    create(index(:urls, [:user_id]))
    create(index(:addresses, [:user_id]))
    create(index(:phone_numbers, [:user_id]))
    create(index(:work_experiences, [:user_id]))
    create(index(:social_media_accounts, [:user_id]))

    execute(
      "CREATE INDEX tags_lower_name_index ON tags (lower(name))",
      "DROP INDEX tags_lower_name_index"
    )
  end
end
