defmodule Vutuv.Repo.Migrations.WorkplacePreferenceBecomesAList do
  use Ecto.Migration

  # On-site, hybrid and remote are not mutually exclusive: somebody can be open
  # to two of them, or to all three. The single-value column shipped hours ago
  # in the same unreleased branch (add_welcome_and_workplace_to_users) forced a
  # choice, so it is replaced by a list before it ever reaches production —
  # which is also why dropping it here is N-1 safe: the deployed release knows
  # neither column.
  #
  # NOT NULL with an empty-array default: "no preference" is the empty list,
  # so no call site has to tell nil and [] apart.
  def change do
    alter table(:users) do
      remove(:desired_workplace_type, :string)
      add(:desired_workplace_types, {:array, :string}, null: false, default: [])
    end
  end
end
