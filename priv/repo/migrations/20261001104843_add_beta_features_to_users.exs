defmodule Vutuv.Repo.Migrations.AddBetaFeaturesToUsers do
  use Ecto.Migration

  # The beta features a member switched on (`Vutuv.Beta`). Additive with a
  # default, so the release still serving during the deploy never notices it.
  # The keys are not constrained here: the registry lives in code, and a key
  # whose feature graduated or was dropped is ignored on read.
  def change do
    alter table(:users) do
      add(:beta_features, {:array, :string}, null: false, default: [])
    end
  end
end
