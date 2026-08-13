defmodule Vutuv.Repo.Migrations.IndexFediverseFollowersByActor do
  @moduledoc """
  An index on the follower's actor address alone, for the head count behind the
  top bar's people total (`Vutuv.Fediverse.distinct_follower_count/0`).

  The table's three unique indexes all lead with the *followed* thing
  (`[user_id, actor_uri]`, `[organization_id, actor_uri]`, `[tag_id, actor_uri]`),
  so none of them can serve a query grouped by the actor: a
  `count(distinct actor_uri)` over the whole table had to read every row. This
  one lets Postgres answer it from the index, which matters because the counter
  asks once a minute for as long as the node is up.

  A plain addition, so it is N-1 compatible: the release still serving traffic
  neither knows nor cares about it.
  """
  use Ecto.Migration

  def change do
    create(index(:fediverse_followers, [:actor_uri]))
  end
end
