defmodule Vutuv.Repo.Migrations.AddTagToFediverseActors do
  @moduledoc """
  Issue #1330, the foundation of it: a **tag** can hold a keypair, so a topic
  can eventually be an ActivityPub `Group` actor anyone on any server can
  follow without a vutuv account.

  Third owner on this table, after the member and the page (#1334), and the
  same shape: a nullable `tag_id` beside the other two, the CHECK widened to
  exactly one of three, and its own unique index because neither existing one
  can police the tag spelling.

  ## Why only this much

  The same reason the page half shipped its keypair alone: everything a remote
  server can *see* — WebFinger on the tag host, the `Group` document, the inbox
  that answers `Follow` with `Accept`, and the `Announce` of a tagged post —
  has to land together. Being findable without an inbox that answers means
  somebody presses Follow on Mastodon and it stays pending forever, which is
  worse than not being findable at all. A keypair has no such problem: nothing
  outside this database can see one.

  It waits for one thing, and that is now true: a tag's slug is its actor name
  with no mapping in between, so the column this hangs off is settled
  (#1337/#1332, v7.276.0). Minting an actor from a slug that still had to be
  renamed would have cost a `Move` per tag.

  N-1 safe: the previous release writes only member and page actors, which
  satisfy the widened CHECK, and reads actors only by `user_id` /
  `organization_id`, which a tag row cannot match.
  """
  use Ecto.Migration

  @check :fediverse_actors_exactly_one_owner

  def up do
    alter table(:fediverse_actors) do
      add(:tag_id, references(:tags, type: :binary_id, on_delete: :delete_all))
    end

    drop(constraint(:fediverse_actors, @check))

    create(
      constraint(:fediverse_actors, @check,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN tag_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    create(unique_index(:fediverse_actors, [:tag_id]))
  end

  def down do
    drop(unique_index(:fediverse_actors, [:tag_id]))
    drop(constraint(:fediverse_actors, @check))

    execute("DELETE FROM fediverse_actors WHERE tag_id IS NOT NULL")

    create(
      constraint(:fediverse_actors, @check,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    alter table(:fediverse_actors) do
      remove(:tag_id)
    end
  end
end
