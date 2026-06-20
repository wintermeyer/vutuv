defmodule Vutuv.Repo.Migrations.AddMutedToFollows do
  use Ecto.Migration

  # Mute is a per-follow flag: you keep following (the relationship and a mutual
  # "vernetzt" status stay), but a muted follow drops out of *your* feed. Plain
  # additive column with a default, so the currently deployed release that never
  # reads it keeps working (N-1 safe).
  def change do
    alter table(:follows) do
      add(:muted, :boolean, default: false, null: false)
    end
  end
end
