defmodule Vutuv.Repo.Migrations.CreateCompoundIndexCompetences do
  use Ecto.Migration

  def change do
  	create index(:competences, [:user_id, :skill_id], unique: true)
  end
end
