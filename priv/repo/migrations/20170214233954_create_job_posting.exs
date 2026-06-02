defmodule Vutuv.Repo.Migrations.CreateJobPosting do
  use Ecto.Migration

  def change do
    create table(:job_postings) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :title, :string
      add :description, :string
      add :location, :string
      add :prerequisites, :string
      add :slug, :string
      add :open_on, :date
      add :closed_on, :date

      timestamps()
    end
    create unique_index(:job_postings, [:slug], unique: true)
  end
end
