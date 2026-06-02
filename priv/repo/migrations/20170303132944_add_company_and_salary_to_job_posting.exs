defmodule Vutuv.Repo.Migrations.AddCompanyAndSalaryToJobPosting do
  use Ecto.Migration

  def change do
    alter table(:job_postings) do
      add :company, :string
      add :min_salary, :integer
      add :max_salary, :integer
      add :currency, :string
      add :remote, :boolean
    end
  end
end
