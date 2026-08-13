defmodule Vutuv.Repo.Migrations.AddTagToFediverseDeliveries do
  @moduledoc """
  Issue #1330: an outbound delivery can belong to a **topic**, so a tag actor
  can sign and send what it owes another server.

  This is what couples the tag inbox to the delivery queue, and it is why this
  one does **not** ship alone the way the keypair and the follower rows did: an
  inbox can record a `Follow` without it, but it cannot answer one, and an
  unanswered Follow shows on Mastodon as pending forever. So the queue is
  widened in the same change that gives the tag an inbox.

  Third owner on this table. No unique index: a delivery row is a queue entry,
  not a relationship — one topic may owe the same inbox several documents at
  once.

  N-1 safe: the previous release writes only member and page deliveries, which
  satisfy the widened CHECK, and its deliverer selects rows preloading `:user`
  and `:organization` and drops anything it cannot sign, so a tag row is inert
  to it rather than confusing.
  """
  use Ecto.Migration

  @check :fediverse_deliveries_exactly_one_sender

  def up do
    alter table(:fediverse_deliveries) do
      add(:tag_id, references(:tags, type: :binary_id, on_delete: :delete_all))
    end

    drop(constraint(:fediverse_deliveries, @check))

    create(
      constraint(:fediverse_deliveries, @check,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN tag_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    create(index(:fediverse_deliveries, [:tag_id]))
  end

  def down do
    drop(index(:fediverse_deliveries, [:tag_id]))
    drop(constraint(:fediverse_deliveries, @check))

    execute("DELETE FROM fediverse_deliveries WHERE tag_id IS NOT NULL")

    create(
      constraint(:fediverse_deliveries, @check,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    alter table(:fediverse_deliveries) do
      remove(:tag_id)
    end
  end
end
