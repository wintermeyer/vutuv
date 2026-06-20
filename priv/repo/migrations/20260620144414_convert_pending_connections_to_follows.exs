defmodule Vutuv.Repo.Migrations.ConvertPendingConnectionsToFollows do
  use Ecto.Migration

  @moduledoc """
  Follow/connect simplification data migration, **retired to a no-op**. It once
  promoted every still-pending connection request to a follow from the requester
  to the other party (via
  `Vutuv.Social.convert_pending_connections_to_follows/0`), so the requester's
  intent survived the removal of the request/accept flow. The `connections`
  table it read has since been dropped and the helper it called is gone, so the
  body is retired.

  It is safe to retire: in production this already ran (deploy 1 of the
  simplification), and on any from-scratch setup the `connections` table is
  empty here, so it converted nothing. The original logic lives in this file's
  git history.
  """

  def up, do: :ok
  def down, do: :ok
end
