defmodule VutuvWeb.DevDocControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth.Scopes

  test "the docs pages render with curl examples, no login needed", %{conn: conn} do
    response = conn |> get(~p"/developers") |> html_response(200)
    assert response =~ "vutuv API"
    assert response =~ "curl"
    assert response =~ "/api/v1/me"

    for page <- ["authentication", "reference"] do
      response = conn |> get("/developers/#{page}") |> html_response(200)
      assert response =~ "curl"
    end
  end

  test "every page serves its raw Markdown under .md", %{conn: _conn} do
    for path <- ["/developers.md", "/developers/authentication.md", "/developers/reference.md"] do
      conn = get(build_conn(), path)
      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/markdown"
      assert conn.resp_body =~ "curl"
    end
  end

  test "unknown pages 404", %{conn: conn} do
    assert get(conn, "/developers/nonsense").status == 404
  end

  test "the scope table in the docs matches the real scope list", %{conn: conn} do
    body = get(conn, "/developers/authentication.md").resp_body

    for scope <- Scopes.all() do
      assert body =~ "`#{scope}`", "scope #{scope} is missing from the documentation"
    end
  end

  test "llms.txt points agents at the API docs", %{conn: conn} do
    body = get(conn, "/llms.txt").resp_body
    assert body =~ "/developers"
    assert body =~ "/api/v1"
  end
end
