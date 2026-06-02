defmodule Vutuv.Repo.Migrations.AddSlugsToWorkExperiences do
  use Ecto.Migration

  def change do
  	alter table(:work_experiences) do
  		add :slug, :string
  	end
  	create unique_index(:work_experiences, :slug, unique: true)
  end
end
