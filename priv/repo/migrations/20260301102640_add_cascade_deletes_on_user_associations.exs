defmodule Vutuv.Repo.Migrations.AddCascadeDeletesOnUserAssociations do
  use Ecto.Migration

  # Constraint names match table names except for renamed tables:
  # - user_skills was originally competences
  # - urls was originally user_urls
  @tables_standard [
    {:emails, :user_id},
    {:magic_links, :user_id},
    {:slugs, :user_id},
    {:search_terms, :user_id},
    {:groups, :user_id},
    {:user_tags, :user_id},
    {:endorsements, :user_id},
    {:user_tag_endorsements, :user_id},
    {:phone_numbers, :user_id},
    {:addresses, :user_id},
    {:work_experiences, :user_id},
    {:social_media_accounts, :user_id},
    {:oauth_providers, :user_id}
  ]

  def up do
    for {table, column} <- @tables_standard do
      drop constraint(table, "#{table}_#{column}_fkey")

      alter table(table) do
        modify column, references(:users, on_delete: :delete_all)
      end
    end

    # Renamed tables have constraint names from their original table names
    drop constraint(:user_skills, "competences_user_id_fkey")

    alter table(:user_skills) do
      modify :user_id, references(:users, on_delete: :delete_all)
    end

    drop constraint(:urls, "user_urls_user_id_fkey")

    alter table(:urls) do
      modify :user_id, references(:users, on_delete: :delete_all)
    end

    # connections has two FK columns referencing users
    drop constraint(:connections, "connections_follower_id_fkey")
    drop constraint(:connections, "connections_followee_id_fkey")

    alter table(:connections) do
      modify :follower_id, references(:users, on_delete: :delete_all)
      modify :followee_id, references(:users, on_delete: :delete_all)
    end
  end

  def down do
    for {table, column} <- @tables_standard do
      drop constraint(table, "#{table}_#{column}_fkey")

      alter table(table) do
        modify column, references(:users, on_delete: :nothing)
      end
    end

    drop constraint(:user_skills, "user_skills_user_id_fkey")

    alter table(:user_skills) do
      modify :user_id, references(:users, on_delete: :nothing)
    end

    drop constraint(:urls, "urls_user_id_fkey")

    alter table(:urls) do
      modify :user_id, references(:users, on_delete: :nothing)
    end

    drop constraint(:connections, "connections_follower_id_fkey")
    drop constraint(:connections, "connections_followee_id_fkey")

    alter table(:connections) do
      modify :follower_id, references(:users, on_delete: :nothing)
      modify :followee_id, references(:users, on_delete: :nothing)
    end
  end
end
