defmodule VutuvWeb.PageHTMLTest do
  use VutuvWeb.ConnCase, async: true

  test "GET /impressum renders the about-us page", %{conn: conn} do
    conn = get(conn, ~p"/impressum")
    body = html_response(conn, 200)

    assert body =~ "Wintermeyer Consulting"
  end
end
