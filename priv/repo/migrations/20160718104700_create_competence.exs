defmodule Vutuv.Repo.Migrations.CreateCompetence do
  use Ecto.Migration

  def change do
    create table(:competences) do
      add :user_id, references(:users, on_delete: :nothing)
      add :skill_id, references(:skills, on_delete: :nothing)

      timestamps()
    end
    create index(:competences, [:user_id])
    create index(:competences, [:skill_id])

  end
end
