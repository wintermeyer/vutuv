defmodule Vutuv.SearchHistoryPruningTest do
  @moduledoc """
  `Vutuv.Search.prune_history/1` bounds the otherwise-unbounded search-history
  tables: it drops queries not searched within the retention window (cascading
  their results and requesters via the FK) and trims old per-search requester
  rows from queries that are still active.
  """
  use Vutuv.DataCase, async: true

  import Ecto.Query

  alias Vutuv.Repo
  alias Vutuv.Search
  alias Vutuv.Search.SearchQuery
  alias Vutuv.Search.SearchQueryRequester
  alias Vutuv.Search.SearchQueryResult

  defp backdate(queryable, days) do
    ts =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-days * 24 * 3600, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.update_all(queryable, set: [inserted_at: ts, updated_at: ts])
  end

  test "drops queries not searched within the window, cascading results + requesters" do
    user = insert_activated_user()

    {:ok, old} = Search.record_query("forgotten term", user)
    Repo.insert!(%SearchQueryResult{search_query_id: old.id, user_id: user.id})

    # Age the whole existing history past the 90-day window.
    backdate(SearchQuery, 120)
    backdate(SearchQueryRequester, 120)

    # A fresh search lands inside the window.
    {:ok, _recent} = Search.record_query("current term", user)

    assert %{search_queries: 1} = Search.prune_history()

    refute Repo.exists?(from(q in SearchQuery, where: q.value == "forgotten term"))
    assert Repo.exists?(from(q in SearchQuery, where: q.value == "current term"))
    # The old query's result + requester cascaded away with it.
    assert Repo.aggregate(SearchQueryResult, :count) == 0
    assert Repo.aggregate(SearchQueryRequester, :count) == 1
  end

  test "trims old requester rows from a still-active query" do
    a = insert_activated_user()
    b = insert_activated_user()

    {:ok, _} = Search.record_query("evergreen", a)
    backdate(SearchQueryRequester, 120)
    # Re-searched now: bumps the query's updated_at and adds a fresh requester.
    {:ok, _} = Search.record_query("evergreen", b)

    Search.prune_history()

    # The query is still active, so it survives...
    assert Repo.exists?(from(q in SearchQuery, where: q.value == "evergreen"))
    # ...but only the fresh requester row remains.
    assert Repo.aggregate(SearchQueryRequester, :count) == 1
  end

  test "keeps everything inside the window" do
    user = insert_activated_user()
    {:ok, _} = Search.record_query("kept", user)

    assert %{search_queries: 0, search_query_requesters: 0} = Search.prune_history()
    assert Repo.aggregate(SearchQuery, :count) == 1
  end
end
