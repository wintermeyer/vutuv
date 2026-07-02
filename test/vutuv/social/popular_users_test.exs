defmodule Vutuv.Social.PopularUsersTest do
  use Vutuv.DataCase

  import Vutuv.QueryCounter

  alias Ecto.Adapters.SQL.Sandbox
  alias Vutuv.Social
  alias Vutuv.Social.PopularUsers

  # An isolated cache instance writing to its own (non-default) table, so these
  # tests never race the application singleton (whose refresh timer is off in
  # tests anyway, see config/test.exs).
  defp start_cache! do
    table = :"popular_users_test_#{System.unique_integer([:positive])}"
    pid = start_supervised!({PopularUsers, name: nil, table: table, refresh?: false})
    Sandbox.allow(Vutuv.Repo, self(), pid)
    {pid, table}
  end

  defp follow_star do
    star = insert_activated_user(first_name: "Stella", last_name: "Star")
    fan = insert_activated_user()
    follow!(fan, star)
    star
  end

  test "refresh snapshots the ranking and top/2 serves it without a query" do
    star = follow_star()
    {pid, table} = start_cache!()

    assert :ok = PopularUsers.refresh(pid)

    {result, queries} = count_queries(fn -> PopularUsers.top(10, table) end)
    assert {:ok, [%{id: id}]} = result
    assert id == star.id
    assert queries == 0
  end

  test "the snapshot is served as-is until the next refresh" do
    follow_star()
    {pid, table} = start_cache!()
    assert :ok = PopularUsers.refresh(pid)

    # A follow landing after the snapshot does not appear until refreshed.
    late_star = follow_star()
    {:ok, users} = PopularUsers.top(10, table)
    refute Enum.any?(users, &(&1.id == late_star.id))

    assert :ok = PopularUsers.refresh(pid)
    {:ok, users} = PopularUsers.top(10, table)
    assert Enum.any?(users, &(&1.id == late_star.id))
  end

  test "top/2 misses on an unseeded or unknown table" do
    {_pid, table} = start_cache!()
    assert PopularUsers.top(10, table) == :miss
    assert PopularUsers.top(10, :no_such_table) == :miss
  end

  test "Social.most_followed_users/1 falls back to the database on a miss" do
    # The application singleton's table exists but is never seeded in tests,
    # so the public API must transparently run the ranking query itself.
    star = follow_star()
    assert [%{id: id}] = Social.most_followed_users(5)
    assert id == star.id
  end

  test "a limit beyond the cached pool size bypasses the cache" do
    follow_star()
    {pid, table} = start_cache!()
    assert :ok = PopularUsers.refresh(pid)

    # The pool caches the top #{PopularUsers.pool_size()}; a larger ask cannot
    # be answered from it and must miss (the caller then queries directly).
    assert PopularUsers.top(PopularUsers.pool_size() + 1, table) == :miss
  end
end
