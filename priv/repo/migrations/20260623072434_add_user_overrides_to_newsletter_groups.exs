defmodule Vutuv.Repo.Migrations.AddUserOverridesToNewsletterGroups do
  use Ecto.Migration

  def change do
    alter table(:newsletter_groups) do
      # Per-account curation on top of the filters: specific members to always
      # include (union) and to always exclude (subtraction wins). Plain id
      # arrays, like the group-level included/excluded_group_ids.
      add(:included_user_ids, {:array, :binary_id}, null: false, default: [])
      add(:excluded_user_ids, {:array, :binary_id}, null: false, default: [])
    end
  end
end
