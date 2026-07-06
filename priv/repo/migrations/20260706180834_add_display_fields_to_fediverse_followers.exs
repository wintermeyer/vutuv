defmodule Vutuv.Repo.Migrations.AddDisplayFieldsToFediverseFollowers do
  use Ecto.Migration

  @moduledoc """
  A remote follower's display identity, captured from its actor document at
  Follow time, so a member can see *who* follows them from the Fediverse (not
  just a count) on the settings page: the handle (`preferredUsername`) and the
  display name. Both nullable — legacy rows and actors that omit them fall
  back to the last path segment of the actor URI. Plain nullable additions,
  N-1 safe.
  """

  def change do
    alter table(:fediverse_followers) do
      add(:handle, :text)
      add(:name, :text)
    end
  end
end
