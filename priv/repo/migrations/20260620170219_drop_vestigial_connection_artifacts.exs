defmodule Vutuv.Repo.Migrations.DropVestigialConnectionArtifacts do
  use Ecto.Migration

  @moduledoc """
  Expand/contract step 2 of 2 for the follow/connect simplification: drop the
  now-vestigial connection artifacts. "Vernetzt" is a mutual follow, derived
  from the `follows` table, so the live code reads none of this any more. The
  release shipping this migration, and the one serving traffic while it runs,
  both stopped touching these columns first (that was the prior deploy). The
  data is redundant: pending requests were already converted to follows, and
  accepted connections always carry both follow edges, so nothing is lost.

  Dropped here:
  - the `connections` table (the old per-pair request/accept record),
  - `users.email_on_connection_request?` (opt-in email for a flow that is gone),
  - the three `moderation_severances` connection columns (a severance now
    restores the "vernetzt" status from its two recorded follow edges alone).
  """

  def up do
    drop(table(:connections))

    alter table(:users) do
      remove(:email_on_connection_request?)
    end

    alter table(:moderation_severances) do
      remove(:had_connection?)
      remove(:connection_status)
      remove(:connection_requested_by_id)
    end
  end

  def down do
    # Best-effort: the schema is recreated, but the dropped rows are not (they
    # were redundant with the follow edges and cannot be reconstructed here).
    create table(:connections) do
      add(:user_a_id, references(:users, on_delete: :delete_all), null: false)
      add(:user_b_id, references(:users, on_delete: :delete_all), null: false)
      add(:requested_by_id, references(:users, on_delete: :delete_all), null: false)
      add(:status, :string, null: false, default: "pending")
      add(:status_changed_at, :naive_datetime)

      timestamps()
    end

    create(unique_index(:connections, [:user_a_id, :user_b_id]))
    create(constraint(:connections, :sorted_pair, check: "user_a_id < user_b_id"))
    create(index(:connections, [:user_b_id]))
    create(index(:connections, [:requested_by_id]))

    alter table(:users) do
      add(:email_on_connection_request?, :boolean, default: false, null: false)
    end

    alter table(:moderation_severances) do
      add(:had_connection?, :boolean, default: false, null: false)
      add(:connection_status, :string)
      add(:connection_requested_by_id, references(:users, on_delete: :nilify_all))
    end
  end
end
