defmodule Vutuv.Repo.Migrations.CreateSkillSynonym do
  use Ecto.Migration

  def change do
    create table(:skill_synonyms) do
    	add :skill_id, references(:skills, on_delete: :delete_all)
    	add :value, :string
      timestamps()
    end
  	create unique_index(:skill_synonyms, [:value], unique: true)
  end
end
