defmodule Vutuv.Repo.Migrations.AddPostsSearchTsv do
  use Ecto.Migration

  def change do
    # Full-text search over post bodies (Vutuv.Posts.search_public/2). A
    # stored generated column keeps the vector in sync with zero app code;
    # 'simple' config (no language stemming) because bodies are mixed
    # German/English. Additive and N-1 safe: the previous release neither
    # selects nor writes the column, and Postgres computes it on insert.
    execute(
      """
      ALTER TABLE posts ADD COLUMN search_tsv tsvector
      GENERATED ALWAYS AS (to_tsvector('simple', coalesce(body, ''))) STORED
      """,
      "ALTER TABLE posts DROP COLUMN search_tsv"
    )

    create(index(:posts, [:search_tsv], using: "GIN"))
  end
end
