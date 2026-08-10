defmodule Vutuv.Repo.Migrations.AddOrganizationAuthorshipToPosts do
  @moduledoc """
  Issue #1334: a post may now be authored by an organization instead of a member.

  Three columns rather than one, because two promises collide.
  `posts.user_id` is `null: false, on_delete: :delete_all` today, which is a
  deliberate promise: deleting your account deletes your posts. But a post
  published for an organization has to survive the person who wrote it leaving.
  Keeping the human in `user_id` would delete the organization's content along
  with their account; dropping the human entirely would leave nobody accountable
  for what was said in the organization's name.

    * `user_id`         — the member, for a personal post; NULL for an organization post
    * `organization_id` — the organization, for an organization post; NULL otherwise
    * `acting_user_id`  — who pressed publish for the organization, `nilify_all`

  The CHECK enforces exactly one of the two authors. `acting_user_id` is not
  optional on the organization path: an organization is a mouth several people
  speak through, and moderation, disputes and departures all need to know which
  one — but it is `nilify_all`, so the record survives that person's account.

  N-1 safe: the previous release only ever writes `user_id`, which still passes
  the CHECK, and the columns it does not know about default to NULL. Dropping
  NOT NULL does not change the column's result type, so no cached prepared
  statement is invalidated by it.
  """
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add(:organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all))
      add(:acting_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
    end

    execute("ALTER TABLE posts ALTER COLUMN user_id DROP NOT NULL")

    create(
      constraint(:posts, :posts_exactly_one_author,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    # An organization page lists its own posts newest-first, the same read the
    # `[user_id, inserted_at]` index serves for a member.
    create(index(:posts, [:organization_id, :inserted_at]))
    # Every post a member published for an organization, for the moderation and
    # departure questions `acting_user_id` exists to answer.
    create(index(:posts, [:acting_user_id]))
  end

  def down do
    drop(index(:posts, [:acting_user_id]))
    drop(index(:posts, [:organization_id, :inserted_at]))
    drop(constraint(:posts, :posts_exactly_one_author))

    execute("DELETE FROM posts WHERE user_id IS NULL")
    execute("ALTER TABLE posts ALTER COLUMN user_id SET NOT NULL")

    alter table(:posts) do
      remove(:acting_user_id)
      remove(:organization_id)
    end
  end
end
