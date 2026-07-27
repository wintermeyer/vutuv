defmodule Vutuv.Repo.Migrations.IndexFediverseReactionsByActor do
  use Ecto.Migration

  # `Vutuv.Fediverse.purge_unreferenced_remote_accounts/0` (issue #1162) asks,
  # per stored account, whether any reaction still names its address. The only
  # index on this table is `unique_index([:post_id, :actor_uri, :kind])`, whose
  # leading column is `post_id`, so that anti-join had to scan the whole
  # reactions table on every hourly sweep — the notes arm gets a real index scan
  # only because `fediverse_notes` carries its own `actor_uri` index.
  #
  # A plain addition, so the currently deployed release keeps working.
  def change do
    create(index(:fediverse_reactions, [:actor_uri]))
  end
end
