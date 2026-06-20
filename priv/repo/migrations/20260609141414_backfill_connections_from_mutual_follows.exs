defmodule Vutuv.Repo.Migrations.BackfillConnectionsFromMutualFollows do
  use Ecto.Migration

  @moduledoc """
  Legacy data migration, **retired to a no-op**. It once promoted every mutual
  follow to an accepted row in the `connections` table (via
  `Vutuv.Social.backfill_connections_from_mutual_follows/0`). That table has
  since been dropped (the follow/connect simplification: "vernetzt" is a mutual
  follow, derived from `follows`), and the helper it called is gone, so the
  body is retired.

  It is safe to retire: in production this already ran, and on any from-scratch
  setup it only ever saw an empty `follows` table here, so it inserted nothing.
  The original logic lives in this file's git history.
  """

  def up, do: :ok
  def down, do: :ok
end
