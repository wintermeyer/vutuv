defmodule Vutuv.Repo.Migrations.AddShowOnlineStatusToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Per-member switch for the real-time "online" green dot on their avatar.
      # Default on so the feature is visible from day one; members opt out on the
      # Privacy settings page, after which they are never tracked or shown as
      # online anywhere. Additive nullable-with-default column, N-1 safe.
      add(:show_online_status?, :boolean, default: true, null: false)
    end
  end
end
