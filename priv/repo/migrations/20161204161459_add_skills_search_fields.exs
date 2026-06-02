defmodule Vutuv.Repo.Migrations.AddSkillsSearchFields do
  use Ecto.Migration

  def change do
  	alter table(:search_terms) do
    	add :skill_id, references(:skills, on_delete: :delete_all)
    end
    alter table(:search_query_results) do
    	add :skill_id, references(:skills, on_delete: :delete_all)
    end
  end
end
