defmodule Vutuv.Repo.Migrations.AddFediverseFollowersToUsers do
  use Ecto.Migration

  @moduledoc """
  The per-member Fediverse opt-in (default off). Federation itself is not
  built yet: the flag ships ahead of the feature to (a) measure real demand
  before investing in ActivityPub and (b) collect the GDPR-clean consent any
  future federation must be gated on — deletion of federated copies on remote
  servers is not enforceable, so federating a member may only ever be opt-in.
  Plain addition, N-1 safe.
  """

  def change do
    alter table(:users) do
      add(:fediverse_followers?, :boolean, default: false, null: false)
    end
  end
end
