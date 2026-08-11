defmodule Vutuv.Repo.Migrations.AddOrganizationToPostMentions do
  @moduledoc """
  Issue #1336: a post may name an **organization** by its root handle, and the
  page should learn about it.

  The nullable pair with a CHECK, like `posts` and `follows` before it.

  N-1 safe, and this time the walk the previous migrations earned found nothing
  to fix: all four existing readers of this table (`Vutuv.Activity`'s
  `mention_events/1` and the thread-precedence `NOT EXISTS`, plus the two
  reconcile queries in `Vutuv.Posts`) compare `user_id` against a real member
  id, so an organization row never matches one of them. No `NOT IN`, and no
  inner join to `users` off the mention row.
  """
  use Ecto.Migration

  def up do
    alter table(:post_mentions) do
      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all)
      )
    end

    execute("ALTER TABLE post_mentions ALTER COLUMN user_id DROP NOT NULL")

    create(
      constraint(:post_mentions, :post_mentions_exactly_one_target,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    # One row per post per page. The existing `[post_id, user_id]` unique index
    # cannot stand in: an organization row leaves `user_id` NULL, and Postgres
    # counts NULLs as distinct, so the `on_conflict: :nothing` reconcile would
    # happily write the same mention twice.
    create(unique_index(:post_mentions, [:post_id, :organization_id]))
    # The page's own activity list reads this way round, newest first.
    create(index(:post_mentions, [:organization_id, :inserted_at]))
  end

  def down do
    drop(index(:post_mentions, [:organization_id, :inserted_at]))
    drop(unique_index(:post_mentions, [:post_id, :organization_id]))
    drop(constraint(:post_mentions, :post_mentions_exactly_one_target))

    execute("DELETE FROM post_mentions WHERE user_id IS NULL")
    execute("ALTER TABLE post_mentions ALTER COLUMN user_id SET NOT NULL")

    alter table(:post_mentions) do
      remove(:organization_id)
    end
  end
end
