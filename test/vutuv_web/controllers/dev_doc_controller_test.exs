defmodule VutuvWeb.DevDocControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth.Scopes

  test "the docs pages render with curl examples, no login needed", %{conn: conn} do
    response = conn |> get(~p"/developers") |> html_response(200)
    assert response =~ "vutuv API"
    assert response =~ "curl"
    assert response =~ "/api/2.0/me"

    for page <- ["authentication", "reference"] do
      response = conn |> get("/developers/#{page}") |> html_response(200)
      assert response =~ "curl"
    end

    assert conn |> get("/developers/webhooks") |> html_response(200) =~ "X-Vutuv-Signature"
  end

  test "every page serves its raw Markdown under .md", %{conn: _conn} do
    for path <- [
          "/developers.md",
          "/developers/authentication.md",
          "/developers/cookbook.md",
          "/developers/data-model.md",
          "/developers/reference.md",
          "/developers/webhooks.md"
        ] do
      conn = get(build_conn(), path)
      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/markdown"
      assert conn.resp_body =~ ~r/^# /
    end
  end

  test "the cookbook answers the basic how-do-I questions with runnable curl", %{conn: conn} do
    response = conn |> get("/developers/cookbook") |> html_response(200)

    # The recipes the docs must answer concretely: posting and direct
    # messages ($API is the base-URL shorthand the page defines up top).
    assert response =~ "https://vutuv.de/api/2.0"
    assert response =~ "$API/posts"
    assert response =~ "/messages"
    assert response =~ "$API/conversations"
    assert response =~ "curl"
  end

  test "the data model page describes the entities and their relationships", %{conn: conn} do
    body = get(conn, "/developers/data-model.md").resp_body

    # The entities a third-party developer works with...
    for entity <- ["member", "post", "conversation", "tag", "follow", "connection"] do
      assert body =~ ~r/#{entity}/i, "data model page does not mention #{entity}"
    end

    # ...and the load-bearing concepts.
    assert body =~ "UUID"
    assert body =~ ~r/denial/i
    assert body =~ ~r/endorsement/i
  end

  test "the overview explains where development happens and how to report bugs", %{conn: conn} do
    response = conn |> get(~p"/developers") |> html_response(200)
    assert response =~ "github.com/wintermeyer/vutuv"
    assert response =~ "github.com/wintermeyer/vutuv/issues"
  end

  test "every docs page links every other docs page in the nav", %{conn: conn} do
    response = conn |> get(~p"/developers") |> html_response(200)

    for page <- ["authentication", "cookbook", "data-model", "reference", "webhooks"] do
      assert response =~ "/developers/#{page}", "docs nav is missing #{page}"
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
    assert body =~ "/api/2.0"
    assert body =~ "/developers/cookbook.md"
    assert body =~ "/developers/data-model.md"
  end
end
