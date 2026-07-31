defmodule Vutuv.Repo.Migrations.AddFediversePostsSearchTsv do
  use Ecto.Migration

  def change do
    # Full-text search over cached remote post bodies, so the tag page's search
    # box asks both sources the same question. The vutuv side has had this since
    # `posts.search_tsv`; without the twin, a search would have matched member
    # posts by word and remote posts by substring (or not at all), and one list
    # cannot honestly mix two search semantics.
    #
    # A stored generated column, exactly like the posts one: zero app code keeps
    # it in sync, and 'simple' (no stemming) because these bodies are in every
    # language the fediverse writes in, not just ours.
    #
    # Additive and N-1 safe: the previous release neither selects nor writes the
    # column, and Postgres computes it on insert.
    execute(
      """
      ALTER TABLE fediverse_posts ADD COLUMN search_tsv tsvector
      GENERATED ALWAYS AS (to_tsvector('simple', coalesce(content_text, ''))) STORED
      """,
      "ALTER TABLE fediverse_posts DROP COLUMN search_tsv"
    )

    create(index(:fediverse_posts, [:search_tsv], using: "GIN"))
  end
end
