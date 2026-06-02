defmodule Vutuv.Repo.Migrations.CreateTagClosure do
  use Ecto.Migration

  def change do
    create table(:tag_closures) do
      add :parent_id, references(:tags, on_delete: :nothing)
      add :child_id, references(:tags, on_delete: :nothing)
      add :depth, :integer

      timestamps()
    end
    create unique_index(:tag_closures, [:parent_id, :child_id], unique: true)
  end
end
