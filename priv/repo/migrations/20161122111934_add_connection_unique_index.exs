defmodule Vutuv.Repo.Migrations.AddConnectionUniqueIndex do
  use Ecto.Migration

  def change do
  	create unique_index(:connections, [:follower_id, :followee_id], unique: true)
  end
end
