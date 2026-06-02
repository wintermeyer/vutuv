defmodule Vutuv.Repo.Migrations.CreateWorkExperience do
  use Ecto.Migration

  def change do
    create table(:work_experiences) do
      add :user_id, references(:users)
    	add :organization, :string
    	add :title, :string
    	add :description, :string
    	add :start_month, :integer
    	add :start_year, :integer
    	add :end_month, :integer
    	add :end_year, :integer
      timestamps()
    end

  end
end
