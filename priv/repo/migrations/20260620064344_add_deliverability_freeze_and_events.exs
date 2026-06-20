defmodule Vutuv.Repo.Migrations.AddDeliverabilityFreezeAndEvents do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # The "frozen because unreachable" state: set when a confirmed account
      # has no deliverable email left (every address bounced) so it can never
      # receive a login PIN again. Distinct from the moderation freeze fields
      # (frozen_at / suspended_until / deactivated_at) on purpose: this is a
      # deliverability fact, not an abuse ruling. While set, the profile is
      # hidden from other members (Vutuv.Moderation.account_hidden?) but stays
      # visible to the owner and admins. Cleared automatically when a login PIN
      # proves an address works again, or by an admin from the deliverability
      # dashboard. Set programmatically only - never cast from params.
      add(:unreachable_at, :naive_datetime)
    end

    # The deliverability audit trail: one row per state transition (address
    # deactivated/recovered, account frozen/thawed), mirroring the moderation
    # event ledger. actor_id is the admin who acted, or NULL for an automatic
    # (system) transition. Like email_bounces, user_id / actor_id are plain
    # binary_id columns, not FKs: this is an immutable ledger that must outlive
    # the rows it references (a departed owner's freeze history stays readable),
    # and keeping it FK-free means user deletion needs no extra cascade step.
    create table(:deliverability_events) do
      add(:user_id, :binary_id)
      add(:email_value, :string)
      add(:actor_id, :binary_id)
      add(:action, :string, null: false)
      add(:detail, :map, null: false, default: %{})

      timestamps(updated_at: false)
    end

    create(index(:deliverability_events, [:user_id]))
    create(index(:deliverability_events, [:inserted_at]))

    # Find frozen-for-unreachability accounts cheaply on the admin dashboard.
    create(index(:users, [:unreachable_at], where: "unreachable_at IS NOT NULL"))

    # All additive and N-1 safe: the currently deployed release never reads the
    # new column or table.
  end
end
