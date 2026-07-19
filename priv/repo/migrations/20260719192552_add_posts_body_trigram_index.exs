defmodule Vutuv.Repo.Migrations.AddPostsBodyTrigramIndex do
  use Ecto.Migration

  # CREATE INDEX CONCURRENTLY cannot run inside a transaction or behind the
  # migrator's advisory lock. posts can be large, so build it CONCURRENTLY to
  # keep post writes flowing during the blue/green deploy.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    # `Vutuv.Mentions.mentioned_in_posts?/1` narrows to candidate rows with
    # `body ILIKE '%@handle%'` — the anti-hijack availability check that runs on
    # every rename and on the live username-availability keystroke. The GIN
    # trigram index turns that leading-wildcard scan from a full posts scan into
    # a bitmap index scan (a 3-char-min handle plus the `@` always has enough
    # trigrams to use it).
    create index(:posts, ["body gin_trgm_ops"],
             using: "GIN",
             name: "posts_body_trgm_index",
             concurrently: true
           )
  end

  def down do
    drop index(:posts, ["body gin_trgm_ops"],
           name: "posts_body_trgm_index",
           concurrently: true
         )

    # pg_trgm is left installed on purpose (other trigram indexes depend on it).
  end
end
