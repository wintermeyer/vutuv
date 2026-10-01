defmodule Vutuv.Repo.Migrations.AddBetaToUsers do
  use Ecto.Migration

  # Whether a member tries beta features (`Vutuv.Beta`). Additive with a
  # default, so the release still serving during the deploy never notices it.
  def change do
    alter table(:users) do
      add(:beta?, :boolean, null: false, default: false)
    end
  end
end
