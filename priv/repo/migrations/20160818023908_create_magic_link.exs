defmodule Vutuv.Repo.Migrations.CreateMagicLink do
  use Ecto.Migration

  def change do
    create table(:magic_links) do
    	add :magic_link, :string
      add :magic_link_type, :string
  		add :magic_link_created_at, :naive_datetime
  		add :user_id, references(:users, on_delete: :nothing)
      timestamps()
    end

    alter table(:users) do
    	remove :magic_link
    	remove :magic_link_created_at
    end
  end

  def down do
    drop table(:magic_links)

    alter table(:users) do
      add :magic_link, :string
      add :magic_link_created_at, :naive_datetime
    end
  end
end
