defmodule Vutuv.ConnectionsBackfillTest do
  @moduledoc """
  The two connection-table data-migration helpers: the legacy backfill that
  promotes mutual follows to accepted connections
  (`Vutuv.Social.backfill_connections_from_mutual_follows/0`), and the
  follow/connect-simplification converter that turns leftover pending requests
  into follows (`Vutuv.Social.convert_pending_connections_to_follows/0`).
  """
  use Vutuv.DataCase

  alias Vutuv.Social
  alias Vutuv.Social.Connection

  defp pending!(requester, other) do
    {user_a, user_b} = Enum.min_max([requester.id, other.id])

    Repo.insert!(%Connection{
      user_a_id: user_a,
      user_b_id: user_b,
      requested_by_id: requester.id,
      status: "pending",
      status_changed_at: NaiveDateTime.utc_now(:second)
    })
  end

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

  describe "convert_pending_connections_to_follows/0" do
    test "promotes each pending request to a follow from requester to the other party" do
      a = insert(:user)
      b = insert(:user)
      pending!(a, b)

      assert Social.convert_pending_connections_to_follows() == 1
      assert Social.user_follows_user?(a.id, b.id)
      # Only the requester's intent becomes a follow, not the reverse.
      refute Social.user_follows_user?(b.id, a.id)
    end

    test "is idempotent and skips a pair that already follows" do
      a = insert(:user)
      b = insert(:user)
      follow!(a, b)
      pending!(a, b)

      assert Social.convert_pending_connections_to_follows() == 0
      assert Social.user_follows_user?(a.id, b.id)
    end

    test "ignores accepted and declined rows" do
      a = insert(:user)
      b = insert(:user)

      pending!(a, b)
      |> Ecto.Changeset.change(status: "declined")
      |> Repo.update!()

      assert Social.convert_pending_connections_to_follows() == 0
      refute Social.user_follows_user?(a.id, b.id)
    end
  end

  defp backdate(%Vutuv.Social.Follow{id: id}, at) do
    Repo.update_all(from(f in Vutuv.Social.Follow, where: f.id == ^id), set: [inserted_at: at])
  end
end
