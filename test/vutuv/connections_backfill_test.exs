defmodule Vutuv.ConnectionsBackfillTest do
  @moduledoc """
  The legacy backfill that promotes mutual follows to accepted connections
  (`Vutuv.Social.backfill_connections_from_mutual_follows/0`), exercised by the
  `BackfillConnectionsFromMutualFollows` migration.
  """
  use Vutuv.DataCase

  alias Vutuv.Social
  alias Vutuv.Social.Connection

  test "promotes mutual follows to accepted connections, ignoring one-way follows" do
    a = insert(:user)
    b = insert(:user)
    c = insert(:user)

    follow!(a, b)
    follow!(b, a)
    # One-way only: must not become a connection.
    follow!(a, c)

    assert Social.backfill_connections_from_mutual_follows() == 1
    assert Social.connected?(a.id, b.id)
    refute Social.connected?(a.id, c.id)
    assert Repo.aggregate(Connection, :count) == 1
  end

  test "is idempotent — a re-run inserts nothing new" do
    a = insert(:user)
    b = insert(:user)
    follow!(a, b)
    follow!(b, a)

    assert Social.backfill_connections_from_mutual_follows() == 1
    assert Social.backfill_connections_from_mutual_follows() == 0
    assert Repo.aggregate(Connection, :count) == 1
  end

  test "requested_by is the earlier follower and status_changed_at the later follow" do
    a = insert(:user)
    b = insert(:user)
    f_ab = follow!(a, b)
    f_ba = follow!(b, a)
    backdate(f_ab, ~N[2020-01-01 00:00:00])
    backdate(f_ba, ~N[2021-01-01 00:00:00])

    Social.backfill_connections_from_mutual_follows()
    connection = Repo.one(Connection)

    assert connection.requested_by_id == a.id
    assert NaiveDateTime.compare(connection.status_changed_at, ~N[2021-01-01 00:00:00]) == :eq
    # Stored canonically regardless of who followed first.
    assert {connection.user_a_id, connection.user_b_id} == Enum.min_max([a.id, b.id])
  end

  defp backdate(%Vutuv.Social.Follow{id: id}, at) do
    Repo.update_all(from(f in Vutuv.Social.Follow, where: f.id == ^id), set: [inserted_at: at])
  end
end
