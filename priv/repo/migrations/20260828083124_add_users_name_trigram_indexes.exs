defmodule Vutuv.Repo.Migrations.AddUsersNameTrigramIndexes do
  use Ecto.Migration

  # The member directory's search box (`Vutuv.Directory.search/3`) matches a
  # typed name with `ILIKE '%needle%'` against `users.first_name`,
  # `users.last_name` and `users.username`. A leading wildcard can use no btree
  # index — `users_username_index` is a plain unique btree, and the two name
  # columns had no index at all — so every debounced keystroke was a sequential
  # scan of `users`. Measured on a 101,558-row copy of production: 26.3 ms per
  # scan, against 1.3 ms once these exist (a BitmapOr over three bitmap index
  # scans). At today's ~6,000 rows the difference is a few milliseconds; the
  # point is that the cost grows with the membership on a page whose whole job
  # is to be typed into.
  #
  # This repo already learned the lesson once, for the same query shape:
  # `20260613195046_add_trigram_index_to_search_terms` records "~280ms full
  # scan → ~2ms bitmap index scan" for the people search on `search_terms`.
  # That table carries first/last/combined names but not usernames, and its
  # matcher ANDs the name fields rather than ORing a caller-chosen subset, so
  # the directory box cannot borrow it.
  #
  # pg_trgm needs three characters to form a trigram, which is why
  # `Directory.min_query_chars/0` is 3: a two-letter needle would plan a
  # sequential scan however many indexes stand here (measured 27.1 ms against
  # 1.3 ms on the same indexed table).
  #
  # Built CONCURRENTLY, so this migration may run neither in a transaction nor
  # behind the migrator's advisory lock. Additive and N-1 compatible: it only
  # speeds up queries, so the release still serving traffic keeps working.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    for column <- ~w(first_name last_name username) do
      create_if_not_exists(
        index(:users, ["#{column} gin_trgm_ops"],
          using: :gin,
          name: "users_#{column}_trgm_index",
          concurrently: true
        )
      )
    end
  end

  def down do
    for column <- ~w(first_name last_name username) do
      drop_if_exists(
        index(:users, ["#{column} gin_trgm_ops"],
          name: "users_#{column}_trgm_index",
          concurrently: true
        )
      )
    end

    # pg_trgm stays installed: the search_terms and tags trigram indexes need it.
  end
end
