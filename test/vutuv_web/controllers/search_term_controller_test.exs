defmodule VutuvWeb.SearchTermControllerTest do
  use VutuvWeb.ConnCase, async: false

  # Search terms are a user's private search history. `SearchTermController`
  # guards the resource with `VutuvWeb.Plug.AuthUser`, so the logged-in user
  # always equals the path (`:user_slug`) user. But `show/2` looked the term up
  # by id alone (`Repo.get!(SearchTerm, id)`), so the owner could read any other
  # user's term by guessing its id (IDOR, audit finding #35). The lookup must be
  # scoped to the owner; a foreign id has to 404.

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{conn: conn, user: user}
  end

  describe "GET /users/:user_slug/search_terms/:id" do
    test "shows the owner's own search term", %{conn: conn, user: user} do
      term = insert(:search_term, user: user)

      conn = get(conn, ~p"/users/#{user}/search_terms/#{term}")

      assert html_response(conn, 200) =~ term.value
    end

    # The scoped `Repo.get_by!` raises `Ecto.NoResultsError` for a foreign id,
    # which `Plug.Exception` maps to a 404 response. In the test env the
    # exception propagates rather than rendering, so assert the sent status with
    # `assert_error_sent/2` (matching the coupon/recruiter controller tests).
    test "404s when the id belongs to another user", %{conn: conn, user: user} do
      other = insert(:user, validated?: true)
      insert(:slug, value: other.active_slug, disabled: false, user: other)
      foreign_term = insert(:search_term, user: other)

      assert_error_sent(404, fn ->
        get(conn, ~p"/users/#{user}/search_terms/#{foreign_term}")
      end)
    end
  end
end
