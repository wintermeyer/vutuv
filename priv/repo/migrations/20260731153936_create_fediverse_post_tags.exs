defmodule Vutuv.Repo.Migrations.CreateFediversePostTags do
  use Ecto.Migration

  # Which of **our** tags a cached remote post carries, so `/tags/:slug` can
  # list posts from other networks beside vutuv's own.
  #
  # Until now a `#hashtag` in a remote post was recognised at render time only:
  # the text was scanned per card, and nothing about it was queryable. A tag
  # page could therefore never ask "and what did the fediverse say about this",
  # which is exactly the question a topic page exists to answer.
  #
  # The row names a tag that **already exists here** — the ingestion never mints
  # one from a stranger's hashtag. Two reasons, and the second is the important
  # one: our tag namespace is what members chose to call things, and a table any
  # remote server may write into is a table any remote server may flood with
  # pages on our own domain.
  #
  # New table only -> N-1 safe for the blue/green window.
  def change do
    create table(:fediverse_post_tags) do
      add(
        :remote_post_id,
        references(:fediverse_posts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :tag_id,
        references(:tags, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps()
    end

    # One row per (post, tag): a post repeating its own hashtag is one filing,
    # and the re-sync on an upstream `Update` leans on this to be idempotent.
    create(unique_index(:fediverse_post_tags, [:remote_post_id, :tag_id]))

    # The tag page's read: every remote post filed under one tag. Carries the
    # post id so the union with the vutuv side stays an index-only scan.
    create(index(:fediverse_post_tags, [:tag_id, :remote_post_id]))
  end
end
