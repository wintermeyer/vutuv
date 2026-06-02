defmodule Vutuv.Repo.Migrations.CreateUserTag do
  use Ecto.Migration

  def change do
    create table(:user_tags) do
      add :user_id, references(:users)
      add :tag_id, references(:tags)

      timestamps()
    end
    create unique_index(:user_tags, [:user_id, :tag_id], unique: true)
  end
end
