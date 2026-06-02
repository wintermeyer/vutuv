defmodule VutuvWeb.LayoutViewTest do
  use VutuvWeb.ConnCase, async: true

  test "the app layout wraps page content with the shared nav and footer", %{conn: conn} do
    conn = get(conn, ~p"/impressum")
    body = html_response(conn, 200)

    assert body =~ "<nav class=\"navigation\">"
    assert body =~ ~p"/datenschutzerklaerung"
  end
end
