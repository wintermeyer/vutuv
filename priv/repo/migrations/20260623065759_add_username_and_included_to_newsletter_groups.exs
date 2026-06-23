defmodule Vutuv.Repo.Migrations.AddUsernameAndIncludedToNewsletterGroups do
  use Ecto.Migration

  def change do
    alter table(:newsletter_groups) do
      # An ILIKE username pattern (`*` wildcard) to filter members by handle.
      add(:username, :string)
      # Other groups whose members are UNIONed into this one (the inverse of
      # excluded_group_ids). Plain id array, like excluded_group_ids.
      add(:included_group_ids, {:array, :binary_id}, null: false, default: [])
    end
  end
end
