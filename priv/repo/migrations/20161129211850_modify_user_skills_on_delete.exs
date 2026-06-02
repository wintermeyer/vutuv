defmodule Vutuv.Repo.Migrations.ModifyUserSkillsOnDelete do
  use Ecto.Migration

  def change do
    execute(drop_fk("endorsements", "endorsements_user_skill_id_fkey"))

    alter table(:endorsements) do
      modify :user_skill_id, references(:user_skills, on_delete: :delete_all)
    end
  end

  # MariaDB drops a foreign key by its name with DROP FOREIGN KEY; PostgreSQL
  # with DROP CONSTRAINT. The constraint name matches Ecto's default on both.
  defp drop_fk(table, name) do
    case repo().__adapter__() do
      Ecto.Adapters.Postgres -> "ALTER TABLE #{table} DROP CONSTRAINT #{name}"
      _ -> "ALTER TABLE #{table} DROP FOREIGN KEY #{name}"
    end
  end
end
