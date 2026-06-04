defmodule VutuvWeb.LayoutHTMLTest do
  use VutuvWeb.ConnCase, async: true

  test "the app layout wraps page content with the shared shell nav and footer", %{conn: conn} do
    conn = get(conn, ~p"/impressum")
    body = html_response(conn, 200)

    # The nav chrome is the embedded ShellLive (top bar + mobile tab bar).
    assert body =~ "id=\"app-shell\""
    assert body =~ ~p"/datenschutzerklaerung"
  end

  test "the footer links to the current GitHub repo and its issue tracker", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)

    assert body =~ "https://github.com/wintermeyer/vutuv"
    assert body =~ "https://github.com/wintermeyer/vutuv/issues/new"
    refute body =~ "github.com/vutuv/vutuv"
  end

  test "the footer copyright spans from 2019 to the current year", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)

    assert body =~ "© 2019 - #{Date.utc_today().year}"
  end

  test "the footer links to wintermeyer-consulting.de without the www host", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)

    assert body =~ "https://wintermeyer-consulting.de"
    refute body =~ "www.wintermeyer-consulting.de"
  end
end
