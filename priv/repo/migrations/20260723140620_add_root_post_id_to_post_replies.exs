defmodule Vutuv.Repo.Migrations.AddRootPostIdToPostReplies do
  use Ecto.Migration

  @moduledoc """
  Denormalizes each reply's thread root onto its `post_replies` row.

  Threading is a parent-pointer chain (a reply is a post, so it can itself be
  replied to), which makes "all replies in this thread" unanswerable without a
  recursive walk. The thread-participation notifications (the "thread" feed
  kind: tell everyone who wrote in a thread about new replies anywhere in it,
  not only the directly answered author) need that set in one indexed lookup,
  so every reply now records its root. Nullable and nilified when the root is
  deleted; a NULL root simply keeps the reply out of thread notifications
  (the chain above it is gone anyway). Plain addition + backfill, so the
  currently deployed release keeps working (N-1 safe).
  """

  def up do
    alter table(:post_replies) do
      add(:root_post_id, references(:posts, on_delete: :nilify_all))
    end

    create(index(:post_replies, [:root_post_id]))

    # Walk each existing reply's parent chain to its top; a chain broken by a
    # deleted ancestor (parent_post_id NULL somewhere above) finds no root and
    # stays NULL.
    execute("""
    WITH RECURSIVE chain AS (
      SELECT pr.id, pr.parent_post_id AS cur
      FROM post_replies pr
      UNION ALL
      SELECT c.id, pr2.parent_post_id
      FROM chain c
      JOIN post_replies pr2 ON pr2.post_id = c.cur
    )
    UPDATE post_replies
    SET root_post_id = c.cur
    FROM chain c
    WHERE post_replies.id = c.id
      AND c.cur IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM post_replies prx WHERE prx.post_id = c.cur)
    """)
  end

  def down do
    alter table(:post_replies) do
      remove(:root_post_id)
    end
  end
end
