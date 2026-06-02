defmodule Vutuv.Repo.Migrations.CreateConnection do
  use Ecto.Migration

  def change do
    create table(:connections) do
      add :follower_id, references(:users, on_delete: :nothing)
      add :followee_id, references(:users, on_delete: :nothing)

      timestamps()
    end
    create index(:connections, [:follower_id])
    create index(:connections, [:followee_id])

  end
end
