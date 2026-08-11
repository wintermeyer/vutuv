defmodule Vutuv.Repo.Migrations.AddOrganizationToFediverseDeliveries do
  @moduledoc """
  Issue #1334: an outbound delivery can belong to a **page**, so a page can sign
  and send what it owes another server.

  This is what couples the inbox to the delivery queue. A page's inbox can
  *record* a Follow without any of this — but it cannot answer it, and an
  unanswered Follow shows on Mastodon as pending forever, which is precisely the
  "presses Follow and nothing happens" failure the whole opt-in gate exists to
  prevent. So the queue is widened together with the inbox, not after it.

  Sixth table to take the nullable pair. No unique index this time: a delivery
  row is a queue entry, not a relationship — the same page may legitimately owe
  the same inbox several documents at once.

  N-1 safe: the previous release only writes member deliveries, which satisfy
  the CHECK, and its deliverer selects rows and joins `users`, so a page row is
  invisible to it rather than confusing.
  """
  use Ecto.Migration

  def up do
    alter table(:fediverse_deliveries) do
      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all)
      )
    end

    execute("ALTER TABLE fediverse_deliveries ALTER COLUMN user_id DROP NOT NULL")

    create(
      constraint(:fediverse_deliveries, :fediverse_deliveries_exactly_one_sender,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    create(index(:fediverse_deliveries, [:organization_id]))
  end

  def down do
    drop(index(:fediverse_deliveries, [:organization_id]))
    drop(constraint(:fediverse_deliveries, :fediverse_deliveries_exactly_one_sender))

    execute("DELETE FROM fediverse_deliveries WHERE user_id IS NULL")
    execute("ALTER TABLE fediverse_deliveries ALTER COLUMN user_id SET NOT NULL")

    alter table(:fediverse_deliveries) do
      remove(:organization_id)
    end
  end
end
