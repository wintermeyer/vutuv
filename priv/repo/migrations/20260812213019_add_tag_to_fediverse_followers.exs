defmodule Vutuv.Repo.Migrations.AddTagToFediverseFollowers do
  @moduledoc """
  Issue #1330: somebody on another server can follow a **topic**, so the row
  that records a remote follower needs a third owner beside the member and the
  page.

  Same shape as the two before it: a nullable `tag_id`, the CHECK widened to
  exactly one of three, and its own unique index — `(tag_id, actor_uri)`, so one
  remote account follows one topic once, which is what makes an `add` idempotent
  when a server re-delivers a `Follow`.

  ## Why this can ship alone

  Nothing writes it yet, and nothing outside this database can see it. The parts
  a remote server *can* see — WebFinger on the tag host, the `Group` document,
  the inbox that answers `Follow` with `Accept` — still have to arrive together:
  a recorded Follow that is never answered shows on Mastodon as pending forever,
  which is the failure the whole gate exists to prevent. So the storage goes
  first, the way it did for the keypair in v7.276.1 and for the page in #1334.

  N-1 safe: the previous release writes only member and page followers, which
  satisfy the widened CHECK, and every query it runs scopes to `user_id` or
  `organization_id`, so a tag row is invisible to it rather than confusing.
  """
  use Ecto.Migration

  @check :fediverse_followers_exactly_one_target

  def up do
    alter table(:fediverse_followers) do
      add(:tag_id, references(:tags, type: :binary_id, on_delete: :delete_all))
    end

    drop(constraint(:fediverse_followers, @check))

    create(
      constraint(:fediverse_followers, @check,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN tag_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    create(unique_index(:fediverse_followers, [:tag_id, :actor_uri]))
  end

  def down do
    drop(unique_index(:fediverse_followers, [:tag_id, :actor_uri]))
    drop(constraint(:fediverse_followers, @check))

    execute("DELETE FROM fediverse_followers WHERE tag_id IS NOT NULL")

    create(
      constraint(:fediverse_followers, @check,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    alter table(:fediverse_followers) do
      remove(:tag_id)
    end
  end
end
