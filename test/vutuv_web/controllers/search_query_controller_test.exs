defmodule VutuvWeb.SearchQueryControllerTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Search.SearchQuery

  describe "POST /search_queries with a blank value" do
    test "does not 500 and re-renders the form with an error", %{conn: conn} do
      conn = post(conn, ~p"/search", search_query: %{"value" => ""})

      body = html_response(conn, 200)
      assert body =~ "can&#39;t be blank"
      refute Repo.exists?(SearchQuery)
    end

    test "treats a whitespace-only value as blank", %{conn: conn} do
      conn = post(conn, ~p"/search", search_query: %{"value" => "   "})

      body = html_response(conn, 200)
      assert body =~ "can&#39;t be blank"
      refute Repo.exists?(SearchQuery)
    end

    test "does not 500 when the value key is missing entirely", %{conn: conn} do
      conn = post(conn, ~p"/search", search_query: %{})

      assert html_response(conn, 200) =~ "can&#39;t be blank"
    end
  end

  describe "repeated search with different capitalization" do
    # The changeset downcases the stored value, so the controller must look the
    # query up downcased too — otherwise a repeat search in another case misses
    # the row and the insert trips the unique index ("has already been taken").
    test "POST reuses the stored query instead of tripping the unique index", %{conn: conn} do
      conn = post(conn, ~p"/search", search_query: %{"value" => "smith"})
      assert redirected_to(conn) == ~p"/search/smith"

      conn = post(conn, ~p"/search", search_query: %{"value" => "Smith"})
      assert redirected_to(conn) == ~p"/search/smith"
    end

    test "GET /search_queries/:id finds the stored query case-insensitively", %{conn: conn} do
      conn = post(conn, ~p"/search", search_query: %{"value" => "smith"})

      conn = get(conn, ~p"/search/Smith")
      body = html_response(conn, 200)
      refute body =~ "already been taken"
    end
  end

  describe "GET /search_queries/new" do
    test "marks the search field as required so blank submits are blocked", %{conn: conn} do
      conn = get(conn, ~p"/search")

      assert html_response(conn, 200) =~ "required"
    end
  end
end
