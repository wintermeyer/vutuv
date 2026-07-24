defmodule Vutuv.Repo.Migrations.AddModerationAdminActions do
  use Ecto.Migration

  def change do
    # The admin-initiated moderation audit trail (issue #812): one row per
    # caseless admin action on an account — freezing or unfreezing it directly
    # from the admin account tool, without a report/case. Mirrors the
    # deliverability_events and moderation_events ledgers. actor_id is the admin
    # who acted; user_id / actor_id are plain binary_id columns, not FKs,
    # because this is an immutable ledger that must outlive the rows it
    # references (a departed member's freeze history stays readable) and keeping
    # it FK-free means account deletion needs no extra cascade step.
    create table(:moderation_admin_actions) do
      add(:user_id, :binary_id)
      add(:actor_id, :binary_id)
      add(:action, :string, null: false)
      add(:reason, :string)
      add(:detail, :map, null: false, default: %{})

      timestamps(updated_at: false)
    end

    create(index(:moderation_admin_actions, [:user_id]))
    create(index(:moderation_admin_actions, [:inserted_at]))

    # All additive and N-1 safe: the currently deployed release never reads the
    # new table.
  end
end
