defmodule Vutuv.Repo.Migrations.CreateFullcontactCache do
  use Ecto.Migration

  def change do
    create table(:fullcontact_caches) do
      add :email_address, :string
      add :content, :text

      timestamps()
    end

  end
end
