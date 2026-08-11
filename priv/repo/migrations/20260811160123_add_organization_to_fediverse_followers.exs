defmodule Vutuv.Repo.Migrations.AddOrganizationToFediverseFollowers do
  @moduledoc """
  Issue #1334: a remote follower can hang off a **page**, not only a member —
  without this there is nowhere to put the follower a page's inbox accepts, so
  the inbox (F4) has no landing place.

  Fifth table to take the nullable pair, and by now the shape is routine:
  `organization_id` beside `user_id`, CHECK for exactly one, and a second unique
  index because the existing `[user_id, actor_uri]` cannot police the
  organization spelling — those rows leave `user_id` NULL and Postgres treats
  NULLs as distinct, so the same remote actor could be recorded twice.

  That second index is not merely tidiness here: `add_follower/2` upserts on
  `conflict_target: [:user_id, :actor_uri]`, so the page twin needs its own
  target to be idempotent, and a repeat Follow from the same server is the
  normal case rather than the exception.

  N-1 safe: the previous release only writes member followers, which satisfy the
  CHECK, and every query it runs is scoped to a real `user_id`.
  """
  use Ecto.Migration

  def up do
    alter table(:fediverse_followers) do
      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all)
      )
    end

    execute("ALTER TABLE fediverse_followers ALTER COLUMN user_id DROP NOT NULL")

    create(
      constraint(:fediverse_followers, :fediverse_followers_exactly_one_target,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    create(unique_index(:fediverse_followers, [:organization_id, :actor_uri]))
  end

  def down do
    drop(unique_index(:fediverse_followers, [:organization_id, :actor_uri]))
    drop(constraint(:fediverse_followers, :fediverse_followers_exactly_one_target))

    execute("DELETE FROM fediverse_followers WHERE user_id IS NULL")
    execute("ALTER TABLE fediverse_followers ALTER COLUMN user_id SET NOT NULL")

    alter table(:fediverse_followers) do
      remove(:organization_id)
    end
  end
end
