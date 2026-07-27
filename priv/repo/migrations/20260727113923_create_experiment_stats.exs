defmodule Vutuv.Repo.Migrations.CreateExperimentStats do
  use Ecto.Migration

  # One counter row per experiment, variant and Berlin calendar day. Aggregate
  # only: no visitor, session or address is recorded, so a leak of this table
  # reveals nothing about anyone. A plain addition, so it is N-1 compatible.
  def change do
    create table(:experiment_stats) do
      add(:experiment, :string, null: false)
      add(:variant, :string, null: false)
      add(:day, :date, null: false)

      add(:views, :integer, null: false, default: 0)
      add(:signups, :integer, null: false, default: 0)
      add(:confirmations, :integer, null: false, default: 0)

      timestamps()
    end

    # The upsert target: every counter bump is an insert with
    # `on_conflict: [inc: [...]]` against this key.
    create(unique_index(:experiment_stats, [:experiment, :variant, :day]))
  end
end
