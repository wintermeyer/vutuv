defmodule Vutuv.Repo.Migrations.RenameUserSkillUniqueIndex do
  use Ecto.Migration

  def change do
  	drop index(:user_skills, [:user_id, :skill_id], name: :competences_user_id_skill_id_index)
  	create index(:user_skills, [:user_id, :skill_id], unique: true)
  end
end
