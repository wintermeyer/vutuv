defmodule Vutuv.Repo.Migrations.BackfillConnectionsFromMutualFollows do
  use Ecto.Migration

  @moduledoc """
  Legacy data migration: every existing mutual follow (A↔B both directions)
  was already treated as a "connection" by the old notification logic, so we
  promote each to a real, accepted `Connection`. One-way follows stay plain
  follows. The follow edges are left untouched.

  The work lives in `Vutuv.Social.backfill_connections_from_mutual_follows/0`
  so it is unit-tested (`test/vutuv/connections_backfill_test.exs`); it is
  idempotent, so a re-run inserts nothing new.
  """

  def up do
    # Disable the per-statement transaction guard is unnecessary here — the
    # backfill is a single idempotent insert_all.
    Vutuv.Social.backfill_connections_from_mutual_follows()
  end

  def down do
    # Not reversible: a backfilled connection is indistinguishable from one
    # later created through the app, so there is nothing safe to undo.
    :ok
  end
end
