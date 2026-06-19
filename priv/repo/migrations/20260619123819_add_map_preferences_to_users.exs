defmodule Vutuv.Repo.Migrations.AddMapPreferencesToUsers do
  use Ecto.Migration

  # Per-viewer map preferences: which map services a logged-in member wants on
  # the addresses they look at, and which one is their default (the one rendered
  # as the primary "Open in …" button). All plain additions with constant
  # defaults, so this is an N-1-compatible, metadata-only change on Postgres:
  # existing rows read as "all three services on, Google the default", which is
  # exactly the behaviour before this feature. See `Vutuv.Maps`.
  def change do
    alter table(:users) do
      add(:map_google?, :boolean, null: false, default: true)
      add(:map_openstreetmap?, :boolean, null: false, default: true)
      add(:map_apple?, :boolean, null: false, default: true)
      add(:default_map_service, :string, null: false, default: "google")
    end
  end
end
