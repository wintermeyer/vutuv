defmodule Vutuv.Repo.Migrations.AddActiveSlug do
  use Ecto.Migration

  def change do
  	alter table(:users) do
  		add :active_slug, :string
  	end
  end
end
