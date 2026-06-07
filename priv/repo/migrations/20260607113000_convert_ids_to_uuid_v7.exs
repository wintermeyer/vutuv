defmodule Vutuv.Repo.Migrations.ConvertIdsToUuidV7 do
  use Ecto.Migration

  # Converts every primary key and foreign key from integer (bigserial) to
  # UUID v7, preserving all parent/child relationships:
  #
  #   1. each row gets a v7 UUID whose 48-bit timestamp comes from its own
  #      inserted_at, so id order still matches creation order (the feed's
  #      keyset pagination tiebreaker `id < ^id` depends on this);
  #   2. child rows copy the parent's new UUID by joining on the old integer
  #      FK, and the migration RAISES (rolling back the whole transaction)
  #      if even one non-NULL link would come out NULL;
  #   3. only then are the integer columns dropped and the constraints and
  #      indexes recreated, byte-identical in name and behavior.
  #
  # Everything runs in one transaction; a failure leaves the database
  # untouched. down/0 raises - restore from the pre-deploy pg_dump
  # (DEPLOY_TODO.md). The table/FK/index inventories below were taken from a
  # fully migrated database (information_schema/pg_indexes), not from the
  # migration history.

  # All 30 live tables (the legacy skill tables are dropped one migration
  # earlier). Every table has inserted_at.
  @tables ~w(
    users emails slugs login_pins oauth_providers search_terms
    locales exonyms groups connections memberships
    addresses phone_numbers social_media_accounts urls work_experiences
    search_queries search_query_requesters search_query_results
    tags user_tags user_tag_endorsements
    posts post_denials post_images post_tags
    post_likes post_bookmarks post_reposts post_replies
  )

  # {child, column, parent, on_delete rule, not_null?} - all 42 belongs_to FKs.
  # Constraint names are uniformly <child>_<column>_fkey.
  @foreign_keys [
    {"emails", "user_id", "users", "CASCADE", false},
    {"slugs", "user_id", "users", "CASCADE", false},
    {"login_pins", "user_id", "users", "CASCADE", false},
    {"oauth_providers", "user_id", "users", "CASCADE", false},
    {"search_terms", "user_id", "users", "CASCADE", false},
    {"exonyms", "locale_id", "locales", "NO ACTION", false},
    {"exonyms", "exonym_locale_id", "locales", "NO ACTION", false},
    {"groups", "user_id", "users", "CASCADE", false},
    {"connections", "follower_id", "users", "CASCADE", false},
    {"connections", "followee_id", "users", "CASCADE", false},
    {"memberships", "connection_id", "connections", "NO ACTION", false},
    {"memberships", "group_id", "groups", "NO ACTION", false},
    {"addresses", "user_id", "users", "CASCADE", false},
    {"phone_numbers", "user_id", "users", "CASCADE", false},
    {"social_media_accounts", "user_id", "users", "CASCADE", false},
    {"urls", "user_id", "users", "CASCADE", false},
    {"work_experiences", "user_id", "users", "CASCADE", false},
    {"search_query_requesters", "user_id", "users", "CASCADE", false},
    {"search_query_requesters", "search_query_id", "search_queries", "CASCADE", false},
    {"search_query_results", "user_id", "users", "CASCADE", false},
    {"search_query_results", "search_query_id", "search_queries", "CASCADE", false},
    {"user_tags", "user_id", "users", "CASCADE", false},
    {"user_tags", "tag_id", "tags", "CASCADE", false},
    {"user_tag_endorsements", "user_id", "users", "CASCADE", false},
    {"user_tag_endorsements", "user_tag_id", "user_tags", "CASCADE", false},
    {"posts", "user_id", "users", "CASCADE", true},
    {"post_denials", "post_id", "posts", "CASCADE", true},
    {"post_denials", "group_id", "groups", "RESTRICT", false},
    {"post_denials", "denied_user_id", "users", "CASCADE", false},
    {"post_images", "post_id", "posts", "CASCADE", false},
    {"post_images", "user_id", "users", "CASCADE", true},
    {"post_tags", "post_id", "posts", "CASCADE", true},
    {"post_tags", "tag_id", "tags", "CASCADE", true},
    {"post_likes", "post_id", "posts", "CASCADE", true},
    {"post_likes", "user_id", "users", "CASCADE", true},
    {"post_bookmarks", "post_id", "posts", "CASCADE", true},
    {"post_bookmarks", "user_id", "users", "CASCADE", true},
    {"post_reposts", "post_id", "posts", "CASCADE", true},
    {"post_reposts", "user_id", "users", "CASCADE", true},
    {"post_replies", "post_id", "posts", "CASCADE", true},
    {"post_replies", "parent_post_id", "posts", "SET NULL", false},
    {"post_replies", "parent_author_id", "users", "SET NULL", false}
  ]

  # {table, columns, unique?, partial-index predicate} - the 34 indexes that
  # involve an id/FK column (in the key or, for post_images, the predicate)
  # and therefore fall together with the dropped integer columns. Names follow
  # the Ecto default <table>_<col1>_..._index.
  @fk_indexes [
    {"emails", ~w(user_id), false, nil},
    {"login_pins", ~w(user_id type), true, nil},
    {"oauth_providers", ~w(user_id provider), true, nil},
    {"exonyms", ~w(value locale_id), true, nil},
    {"groups", ~w(user_id), false, nil},
    {"connections", ~w(follower_id), false, nil},
    {"connections", ~w(followee_id), false, nil},
    {"connections", ~w(follower_id followee_id), true, nil},
    {"memberships", ~w(connection_id), false, nil},
    {"memberships", ~w(group_id), false, nil},
    {"user_tags", ~w(user_id tag_id), true, nil},
    {"user_tags", ~w(tag_id), false, nil},
    {"user_tag_endorsements", ~w(user_id user_tag_id), true, nil},
    {"user_tag_endorsements", ~w(user_tag_id), false, nil},
    {"posts", ~w(user_id published_on seq), true, nil},
    {"posts", ~w(user_id inserted_at), false, nil},
    {"post_denials", ~w(post_id group_id), true, nil},
    {"post_denials", ~w(post_id denied_user_id), true, nil},
    {"post_denials", ~w(post_id wildcard), true, nil},
    {"post_denials", ~w(group_id), false, nil},
    {"post_denials", ~w(denied_user_id), false, nil},
    {"post_images", ~w(post_id), false, nil},
    {"post_images", ~w(inserted_at), false, "post_id IS NULL"},
    {"post_tags", ~w(post_id tag_id), true, nil},
    {"post_tags", ~w(tag_id), false, nil},
    {"post_likes", ~w(post_id user_id), true, nil},
    {"post_likes", ~w(user_id inserted_at), false, nil},
    {"post_bookmarks", ~w(post_id user_id), true, nil},
    {"post_bookmarks", ~w(user_id inserted_at), false, nil},
    {"post_reposts", ~w(post_id user_id), true, nil},
    {"post_reposts", ~w(user_id inserted_at), false, nil},
    {"post_replies", ~w(post_id), true, nil},
    {"post_replies", ~w(parent_post_id), false, nil},
    {"post_replies", ~w(parent_author_id inserted_at), false, nil}
  ]

  # Verbatim from 20260606105703_create_posts.exs.
  @exactly_one_target """
  (CASE WHEN group_id IS NOT NULL THEN 1 ELSE 0 END +
   CASE WHEN denied_user_id IS NOT NULL THEN 1 ELSE 0 END +
   CASE WHEN wildcard IS NOT NULL THEN 1 ELSE 0 END) = 1
  """

  def up do
    # v7 UUID whose timestamp encodes ts. Takes timestamp WITHOUT time zone
    # (inserted_at's type): extract(epoch ...) then reads it as UTC regardless
    # of the session timezone. Random bits from gen_random_uuid() (core since
    # PG 13); overlay replaces bytes 1-6 with the 48-bit millisecond
    # timestamp; set_bit 52/53 turns the version nibble 0100 (v4) into 0111
    # (v7); the variant bits are kept from the v4 value.
    execute("""
    CREATE FUNCTION vutuv_uuid_v7_at(ts timestamp) RETURNS uuid AS $$
      SELECT encode(
        set_bit(
          set_bit(
            overlay(uuid_send(gen_random_uuid())
                    placing substring(int8send((floor(extract(epoch FROM ts) * 1000))::bigint) from 3)
                    from 1 for 6),
            52, 1),
          53, 1),
        'hex')::uuid
    $$ LANGUAGE sql VOLATILE
    """)

    # 1. Every row gets a v7 id stamped with its own creation time.
    for table <- @tables do
      execute("ALTER TABLE #{table} ADD COLUMN id_new uuid")

      execute(
        "UPDATE #{table} SET id_new = vutuv_uuid_v7_at(COALESCE(inserted_at, (now() AT TIME ZONE 'UTC')))"
      )

      execute("ALTER TABLE #{table} ALTER COLUMN id_new SET NOT NULL")
    end

    # 2. Children copy the parent's new id across the old integer link.
    for {child, column, parent, _on_delete, _not_null} <- @foreign_keys do
      execute("ALTER TABLE #{child} ADD COLUMN #{column}_new uuid")

      execute("""
      UPDATE #{child} SET #{column}_new = parent.id_new
      FROM #{parent} AS parent WHERE #{child}.#{column} = parent.id
      """)
    end

    # 3. Safety gate: a non-NULL integer FK whose UUID twin came out NULL
    #    means a lost relationship - abort (and roll back) instead.
    for {child, column, parent, _on_delete, _not_null} <- @foreign_keys do
      execute("""
      DO $$
      DECLARE lost bigint;
      BEGIN
        SELECT count(*) INTO lost FROM #{child}
        WHERE #{column} IS NOT NULL AND #{column}_new IS NULL;
        IF lost > 0 THEN
          RAISE EXCEPTION 'UUID conversion would lose % #{child}.#{column} -> #{parent} link(s)', lost;
        END IF;
      END $$
      """)
    end

    for {child, column, _parent, _on_delete, true} <- @foreign_keys do
      execute("ALTER TABLE #{child} ALTER COLUMN #{column}_new SET NOT NULL")
    end

    # 4. Tear down the integer ids. FK constraints must go before the parent
    #    id columns they reference; dropping a column then auto-drops its
    #    PK constraint, bigserial sequence and any index using it.
    execute("ALTER TABLE post_denials DROP CONSTRAINT exactly_one_target")

    for {child, column, _parent, _on_delete, _not_null} <- @foreign_keys do
      execute("ALTER TABLE #{child} DROP CONSTRAINT #{child}_#{column}_fkey")
      execute("ALTER TABLE #{child} DROP COLUMN #{column}")
    end

    for table <- @tables do
      execute("ALTER TABLE #{table} DROP COLUMN id")
    end

    # 5. The UUID columns take over the original names.
    for table <- @tables do
      execute("ALTER TABLE #{table} RENAME COLUMN id_new TO id")
    end

    for {child, column, _parent, _on_delete, _not_null} <- @foreign_keys do
      execute("ALTER TABLE #{child} RENAME COLUMN #{column}_new TO #{column}")
    end

    # 6. Primary keys back first (FKs below reference them). This also
    #    normalizes the two legacy names from renamed tables
    #    (magic_links_pkey, user_urls_pkey) to <table>_pkey.
    for table <- @tables do
      execute("ALTER TABLE #{table} ADD CONSTRAINT #{table}_pkey PRIMARY KEY (id)")
    end

    # 7. Foreign keys with their original delete rules and names.
    for {child, column, parent, on_delete, _not_null} <- @foreign_keys do
      execute("""
      ALTER TABLE #{child} ADD CONSTRAINT #{child}_#{column}_fkey
      FOREIGN KEY (#{column}) REFERENCES #{parent}(id) ON DELETE #{on_delete}
      """)
    end

    # 8. Indexes back under their original (Ecto default) names.
    for {table, columns, unique?, predicate} <- @fk_indexes do
      name = "#{table}_#{Enum.join(columns, "_")}_index"
      unique = if unique?, do: " UNIQUE", else: ""
      where = if predicate, do: " WHERE #{predicate}", else: ""

      execute(
        "CREATE#{unique} INDEX #{name} ON #{table} (#{Enum.join(columns, ", ")})#{where}"
      )
    end

    execute(
      "ALTER TABLE post_denials ADD CONSTRAINT exactly_one_target CHECK (#{@exactly_one_target})"
    )

    execute("DROP FUNCTION vutuv_uuid_v7_at(timestamp)")
  end

  def down do
    raise Ecto.MigrationError,
      message: "irreversible: restore the integer ids from the pre-deploy pg_dump"
  end
end
