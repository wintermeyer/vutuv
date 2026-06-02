defmodule Vutuv.Repo.Migrations.CreatePhoneNumber do
  use Ecto.Migration

  def change do
    create table(:phone_numbers) do
  		add :user_id, references(:users)

  		add :value, :string
  		add :number_type, :string

  		timestamps()
  	end

  end
end
