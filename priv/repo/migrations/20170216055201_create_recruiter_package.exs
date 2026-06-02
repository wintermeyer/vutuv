defmodule Vutuv.Repo.Migrations.CreateRecruiterPackage do
  use Ecto.Migration

  def change do
    create table(:recruiter_packages) do
      add :name, :string
      add :description, :string
      add :slug, :string
      add :locale_id, references(:locales, on_delete: :nothing)
      add :price, :float
      add :currency, :string
      add :duration_in_months, :integer
      add :auto_renewal, :boolean, default: true
      add :offer_begins, :date
      add :offer_ends, :date
      add :max_job_postings, :integer

      timestamps()
    end
    create unique_index(:recruiter_packages, [:slug], unique: true)

  end
end
