defmodule Vutuv.Repo.Migrations.CreateEmail do
  use Ecto.Migration

  def change do
    create table(:emails) do
      add :value, :string
      add :md5sum, :string
      add :user_id, references(:users, on_delete: :nothing)

      timestamps()
    end
    create index(:emails, [:user_id])

  end
end
