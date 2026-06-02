defmodule Vutuv.Repo.Migrations.UpdateTagOnDelete do
  use Ecto.Migration

  def change do
    execute(drop_fk("user_tag_endorsements", "user_tag_endorsements_user_tag_id_fkey"))
    execute(drop_fk("user_tags", "user_tags_tag_id_fkey"))
    execute(drop_fk("tag_closures", "tag_closures_child_id_fkey"))
    execute(drop_fk("tag_closures", "tag_closures_parent_id_fkey"))

    alter table(:user_tag_endorsements) do
      modify :user_tag_id, references(:user_tags, on_delete: :delete_all)
    end

    alter table(:user_tags) do
      modify :tag_id, references(:tags, on_delete: :delete_all)
    end

    alter table(:tag_closures) do
      modify :child_id, references(:tags, on_delete: :delete_all)
      modify :parent_id, references(:tags, on_delete: :delete_all)
    end
  end

  def down do
    execute(drop_fk("user_tag_endorsements", "user_tag_endorsements_user_tag_id_fkey"))
    execute(drop_fk("user_tags", "user_tags_tag_id_fkey"))
    execute(drop_fk("tag_closures", "tag_closures_child_id_fkey"))
    execute(drop_fk("tag_closures", "tag_closures_parent_id_fkey"))

    alter table(:user_tag_endorsements) do
      modify :user_tag_id, references(:user_tags)
    end

    alter table(:user_tags) do
      modify :tag_id, references(:tags)
    end

    alter table(:tag_closures) do
      modify :child_id, references(:tags)
      modify :parent_id, references(:tags)
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
