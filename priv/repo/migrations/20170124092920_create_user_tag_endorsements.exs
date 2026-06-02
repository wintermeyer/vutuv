defmodule Vutuv.Repo.Migrations.CreateUserTagEndorsement do
  use Ecto.Migration

  def change do
    create table(:user_tag_endorsements) do
			add :user_id, references(:users, on_delete: :nothing)
    	add :user_tag_id, references(:user_tags, on_delete: :nothing)
      timestamps()
    end
		create index(:user_tag_endorsements, [:user_id, :user_tag_id], unique: true)
  end
end
