defmodule Vutuv.Repo.Migrations.AddOrganizationToFediverseActors do
  @moduledoc """
  Issue #1334, the foundation of its fediverse half: an **organization** can
  hold a keypair, so a page can eventually be an ActivityPub actor of its own.

  Fourth table to take the nullable pair (`follows`, `tag_follows`, and the
  authorship columns on `posts` before it): a nullable `organization_id` beside
  `user_id`, CHECK for exactly one, and a second unique index because the
  existing one on `user_id` cannot police the organization spelling.

  ## Why only this much

  The rest of that half — WebFinger for a page handle, an `Organization` actor
  document, delivery signed as the page, and an inbox that answers Follow —
  cannot ship in pieces: discovery without a working inbox means somebody on
  Mastodon presses Follow and nothing ever happens, which is worse than not
  being findable. A **keypair** has no such problem, because nothing outside
  this database can see one. So the schema goes first and alone, the way it did
  for `follows` in v7.248.1, and the externally visible parts land together.

  N-1 safe: the previous release only writes member actors, which satisfy the
  CHECK, and only ever reads `Repo.get_by(Actor, user_id: …)`, which an
  organization row cannot match.
  """
  use Ecto.Migration

  def up do
    alter table(:fediverse_actors) do
      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all)
      )
    end

    execute("ALTER TABLE fediverse_actors ALTER COLUMN user_id DROP NOT NULL")

    create(
      constraint(:fediverse_actors, :fediverse_actors_exactly_one_owner,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    create(unique_index(:fediverse_actors, [:organization_id]))
  end

  def down do
    drop(unique_index(:fediverse_actors, [:organization_id]))
    drop(constraint(:fediverse_actors, :fediverse_actors_exactly_one_owner))

    execute("DELETE FROM fediverse_actors WHERE user_id IS NULL")
    execute("ALTER TABLE fediverse_actors ALTER COLUMN user_id SET NOT NULL")

    alter table(:fediverse_actors) do
      remove(:organization_id)
    end
  end
end
