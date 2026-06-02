defmodule Vutuv.Repo.Migrations.CreateUser do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :first_name, :string
      add :last_name, :string
      add :middlename, :string
      add :nickname, :string
      add :honorific_prefix, :string
      add :honorific_suffix, :string
      add :gender, :string
      add :birthdate, :date

      timestamps()
    end

  end
end
