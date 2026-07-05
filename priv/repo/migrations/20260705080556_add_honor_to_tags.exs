defmodule Vutuv.Repo.Migrations.AddHonorToTags do
  use Ecto.Migration

  # An honor tag is reserved site-wide: only site admins can assign or remove it
  # (e.g. the "vutuv_developer" badge). Plain additive column, default false, so
  # the previous release (which never writes it) keeps working during a
  # blue/green deploy — N-1 safe, one deploy.
  def change do
    alter table(:tags) do
      add(:honor?, :boolean, default: false, null: false)
    end
  end
end
