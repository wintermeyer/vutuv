defmodule Vutuv.Posts.TopPostersTest do
  use Vutuv.DataCase

  import Vutuv.QueryCounter

  alias Ecto.Adapters.SQL.Sandbox
  alias Vutuv.Posts
  alias Vutuv.Posts.TopPosters

  # An isolated cache instance writing to its own (non-default) table, so these
  # tests never race the application singleton (whose refresh timer is off in
  # tests anyway, see config/test.exs).
  defp start_cache! do
    table = :"top_posters_test_#{System.unique_integer([:positive])}"
    pid = start_supervised!({TopPosters, name: nil, table: table, refresh?: false})
    Sandbox.allow(Vutuv.Repo, self(), pid)
    {pid, table}
  end

  defp poster do
    author = insert_activated_user()
    insert(:post, user: author)
    author
  end

  test "refresh snapshots the pool and top/3 serves it without a query" do
    author = poster()
    {pid, table} = start_cache!()

    assert :ok = TopPosters.refresh(pid)

    {result, queries} = count_queries(fn -> TopPosters.top(28, 10, table) end)
    assert {:ok, [%{id: id}]} = result
    assert id == author.id
    assert queries == 0
  end

  test "the snapshot is served as-is until the next refresh" do
    poster()
    {pid, table} = start_cache!()
    assert :ok = TopPosters.refresh(pid)

    # A poster arriving after the snapshot does not appear until refreshed.
    late = poster()
    {:ok, users} = TopPosters.top(28, 10, table)
    refute Enum.any?(users, &(&1.id == late.id))

    assert :ok = TopPosters.refresh(pid)
    {:ok, users} = TopPosters.top(28, 10, table)
    assert Enum.any?(users, &(&1.id == late.id))
  end

  test "top/3 misses on an unseeded table, an unknown table, or a foreign window" do
    {pid, table} = start_cache!()
    assert TopPosters.top(28, 10, table) == :miss
    assert TopPosters.top(28, 10, :no_such_table) == :miss

    assert :ok = TopPosters.refresh(pid)
    # A window or limit the snapshot was not built for must miss, never lie.
    assert TopPosters.top(7, 10, table) == :miss
    assert TopPosters.top(28, TopPosters.pool_size() + 1, table) == :miss
  end

  test "Posts.top_recent_posters/2 falls back to the database on a miss" do
    # The application singleton never refreshes in tests, so this exercises
    # the miss path end to end: fresh data, straight from the query.
    author = poster()
    assert Enum.map(Posts.top_recent_posters(28, 10), & &1.id) == [author.id]
  end
end
