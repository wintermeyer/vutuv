defmodule Vutuv.Repo.Migrations.AddPerformanceIndexes do
  use Ecto.Migration

  # Additive, hot-path indexes feeding the LiveView read paths. All are built
  # CONCURRENTLY (so no migration may run in a transaction or behind the
  # migrator's advisory lock) to keep writes flowing during the blue/green
  # deploy. Every index here is N-1 compatible: it only speeds up existing
  # queries, so the currently deployed release keeps working unchanged.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # `messages.sender_id` is a foreign key with no index, yet it is filtered on
    # the hottest chat reads: the per-conversation unread count and the global
    # unread-conversations badge that ShellLive recomputes on every page load
    # (`m.sender_id != ^me_id`), plus the preview's own-vs-other check. The
    # existing (conversation_id, inserted_at, id) composite bounds the scan per
    # conversation; this index serves the sender predicate directly and the
    # user-deletion sender nilify cascade.
    create_if_not_exists(index(:messages, [:sender_id], concurrently: true))

    # Every content report resolves an existing case by content before opening a
    # new one (`find_open_case` / `find_resolved_edited_case` filter on
    # content_id + content_type). moderation_cases is only indexed on `status`
    # (low selectivity) and `owner_id`, so those lookups scan. content_id leads
    # (high selectivity); content_type narrows the type tag.
    create_if_not_exists(
      index(:moderation_cases, [:content_id, :content_type], concurrently: true)
    )

    # The people/tag search runs leading-wildcard `ILIKE '%needle%'` on these
    # columns per settled keystroke (Vutuv.Search.visible_tags / filter_tag /
    # filter_city). Without a trigram index each is a sequential scan; the GIN
    # trigram index turns it into a bitmap index scan, exactly as already done
    # for search_terms. pg_trgm is created by that earlier migration.
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    create_if_not_exists(
      index(:tags, ["name gin_trgm_ops"],
        using: "GIN",
        name: "tags_name_trgm_index",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:addresses, ["city gin_trgm_ops"],
        using: "GIN",
        name: "addresses_city_trgm_index",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(index(:messages, [:sender_id], concurrently: true))

    drop_if_exists(index(:moderation_cases, [:content_id, :content_type], concurrently: true))

    drop_if_exists(
      index(:tags, ["name gin_trgm_ops"], name: "tags_name_trgm_index", concurrently: true)
    )

    drop_if_exists(
      index(:addresses, ["city gin_trgm_ops"],
        name: "addresses_city_trgm_index",
        concurrently: true
      )
    )

    # pg_trgm stays installed (the search_terms trigram index still needs it).
  end
end
