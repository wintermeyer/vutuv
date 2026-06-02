defmodule Vutuv.Repo.Migrations.CreateEndorsement do
  use Ecto.Migration

  def change do
  	rename table(:competences) , to: table(:user_skills)
  	
    create table(:endorsements) do
    	add :user_id, references(:users, on_delete: :nothing)
    	add :user_skill_id, references(:user_skills, on_delete: :nothing)

      timestamps()
    end
		create index(:endorsements, [:user_id, :user_skill_id], unique: true)
  end
end
