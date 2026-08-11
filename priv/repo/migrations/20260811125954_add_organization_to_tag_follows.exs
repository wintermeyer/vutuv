defmodule Vutuv.Repo.Migrations.AddOrganizationToTagFollows do
  @moduledoc """
  Issue #1336: a **page** may follow a tag, so its feed can carry a topic and
  not only the people and pages it follows.

  Third table to take the nullable pair (`handles`, `posts`, `follows` before
  it), and by now the shape is routine: a nullable `organization_id` beside
  `user_id`, a CHECK for exactly one, and a second unique index because the
  existing `[user_id, tag_id]` cannot police the organization spelling — those
  rows leave `user_id` NULL and Postgres treats NULLs as distinct, so the same
  subscription would be accepted twice.

  Note this is where Stefan's "tags and remote accounts" splits in two. Tags
  need nothing but this. A page following a *remote* account does not: the
  fediverse actor is keyed to a member (`%Vutuv.Fediverse.Actor{user_id: …}`)
  and carries the keypair that signs the outgoing Follow, so a page cannot send
  one until it has an actor document of its own — which is #1334's fediverse
  half. That table is deliberately left alone here.

  N-1 safe. The previous release only writes member subscriptions, which
  satisfy the CHECK, and every query it runs is scoped to a real `user_id`, so
  an organization row is invisible to it rather than confusing.
  """
  use Ecto.Migration

  def up do
    alter table(:tag_follows) do
      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all)
      )
    end

    execute("ALTER TABLE tag_follows ALTER COLUMN user_id DROP NOT NULL")

    create(
      constraint(:tag_follows, :tag_follows_exactly_one_follower,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    create(unique_index(:tag_follows, [:organization_id, :tag_id]))
  end

  def down do
    drop(unique_index(:tag_follows, [:organization_id, :tag_id]))
    drop(constraint(:tag_follows, :tag_follows_exactly_one_follower))

    execute("DELETE FROM tag_follows WHERE user_id IS NULL")
    execute("ALTER TABLE tag_follows ALTER COLUMN user_id SET NOT NULL")

    alter table(:tag_follows) do
      remove(:organization_id)
    end
  end
end
