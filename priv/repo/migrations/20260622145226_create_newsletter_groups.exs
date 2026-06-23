defmodule Vutuv.Repo.Migrations.CreateNewsletterGroups do
  use Ecto.Migration

  def change do
    # A newsletter audience ("group"): a fixed snapshot of members built from
    # filters (language/country/age/tag) minus other groups, optionally capped.
    # The filter criteria are stored so the group can be re-previewed/edited; the
    # actual membership is materialized into newsletter_group_members on save, so
    # "test run of 100, then the rest" partitions cleanly.
    create table(:newsletter_groups) do
      add(:name, :string, null: false)
      add(:locales, {:array, :string}, null: false, default: [])
      add(:country, :string)
      add(:min_age, :integer)
      add(:max_age, :integer)
      add(:tag_id, references(:tags, on_delete: :nilify_all))
      add(:max_size, :integer)
      # Provenance: the groups whose members were subtracted at build time. Stored
      # as a plain id array (not FKs) — it only records how the snapshot was made.
      add(:excluded_group_ids, {:array, :binary_id}, null: false, default: [])
      add(:member_count, :integer, null: false, default: 0)
      timestamps()
    end

    # The frozen membership snapshot: one row per member in the group.
    create table(:newsletter_group_members) do
      add(:group_id, references(:newsletter_groups, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      timestamps()
    end

    create(unique_index(:newsletter_group_members, [:group_id, :user_id]))
    # For the "subtract this group" exclusion subquery and member-cleanup on user delete.
    create(index(:newsletter_group_members, [:user_id]))

    # Which audience a newsletter was broadcast to (nil = all eligible members).
    alter table(:newsletters) do
      add(:group_id, references(:newsletter_groups, on_delete: :nilify_all))
    end
  end
end
