defmodule Vutuv.Repo.Migrations.AddColumnsToSlugs do
  use Ecto.Migration

  def change do
  	alter table(:slugs) do
  		add :disabled, :boolean, default: false
   	end
  end
end
