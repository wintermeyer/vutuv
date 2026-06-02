defmodule Vutuv.Repo.Migrations.AlterAddressColumns do
  use Ecto.Migration

  def change do
  	alter table(:addresses) do
    	add :line_3, :string
    	add :line_4, :string
  	end
  end

  def down do
  	alter table(:addresses) do
    	remove :line_3
    	remove :line_4
  	end
  end
end
