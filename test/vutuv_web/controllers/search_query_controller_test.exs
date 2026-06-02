defmodule VutuvWeb.SearchQueryControllerTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Search.SearchQuery

  describe "POST /search_queries with a blank value" do
    test "does not 500 and re-renders the form with an error", %{conn: conn} do
      conn = post(conn, ~p"/search_queries", search_query: %{"value" => ""})

      body = html_response(conn, 200)
      assert body =~ "can&#39;t be blank"
      refute Repo.exists?(SearchQuery)
    end

    test "treats a whitespace-only value as blank", %{conn: conn} do
      conn = post(conn, ~p"/search_queries", search_query: %{"value" => "   "})

      body = html_response(conn, 200)
      assert body =~ "can&#39;t be blank"
      refute Repo.exists?(SearchQuery)
    end

    test "does not 500 when the value key is missing entirely", %{conn: conn} do
      conn = post(conn, ~p"/search_queries", search_query: %{})

      assert html_response(conn, 200) =~ "can&#39;t be blank"
    end
  end

  describe "GET /search_queries/new" do
    test "marks the search field as required so blank submits are blocked", %{conn: conn} do
      conn = get(conn, ~p"/search_queries/new")

      assert html_response(conn, 200) =~ "required"
    end
  end
end
