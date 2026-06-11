defmodule Vutuv.Repo.Migrations.AddApprovalToAds do
  use Ecto.Migration

  # Plain addition (two nullable columns), N-1 compatible in one deploy.
  # Existing rows stay unapproved (approved_at NULL) and stop serving until
  # an admin approves them - the safe default for a review gate.
  def change do
    alter table(:ads) do
      # NULL = waiting for the admin review; serving requires a timestamp.
      add(:approved_at, :utc_datetime)
      add(:approved_by_id, references(:users, type: :binary_id, on_delete: :nilify_all))
    end
  end
end
