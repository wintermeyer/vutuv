defmodule Vutuv.Repo.Migrations.AddKindToWorkExperiences do
  use Ecto.Migration

  # Issue #840: work experiences carry a category (employment | internship |
  # volunteer) so a CV reader can tell a paid job from a Praktikum or an
  # Ehrenamt. Additive with a default, so the previous release keeps working
  # (N-1): its INSERTs simply get "employment", which is also the correct
  # reading of every pre-existing row.
  def change do
    alter table(:work_experiences) do
      add(:kind, :string, null: false, default: "employment")
    end
  end
end
