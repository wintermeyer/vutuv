defmodule Vutuv.Repo.Migrations.MakeSkillDowncaseNameUnique do
  use Ecto.Migration

  def change do
  	#drop index(:skills, [:name])
  	create index(:skills, [:downcase_name], unique: true)
  end
end
