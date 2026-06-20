defmodule Vutuv.Repo.Migrations.ConvertPendingConnectionsToFollows do
  use Ecto.Migration

  @moduledoc """
  Follow/connect simplification: the mutual connection request/accept flow is
  gone — there is only "follow", and a mutual follow *is* the connection
  ("vernetzt"). Outstanding pending requests carried intent ("I want a
  relationship"), so preserve each as a follow from the requester to the other
  party; a follow-back then makes the pair vernetzt. Accepted connections
  already have both follow edges; declined ones held no intent worth keeping.

  The work lives in `Vutuv.Social.convert_pending_connections_to_follows/0` so
  it is unit-tested; it is idempotent. On a fresh database `follows`/
  `connections` are empty here, so this inserts nothing.
  """

  def up do
    Vutuv.Social.convert_pending_connections_to_follows()
  end

  def down do
    # Not reversible: a converted follow is indistinguishable from one a member
    # later created through the app, so there is nothing safe to undo.
    :ok
  end
end
