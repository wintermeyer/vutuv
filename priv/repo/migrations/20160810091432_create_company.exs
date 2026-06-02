defmodule Vutuv.Repo.Migrations.CreateCompany do
  use Ecto.Migration

  def change do
    create table(:companies) do
    	add :name, :string
      timestamps()
    end
    alter table(:work_experiences) do

    	add :company_id, references(:companies)
    end
  end
end
