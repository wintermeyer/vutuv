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

  test "the footer is shown on mobile and centered, not hidden behind a breakpoint", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)
    footer = footer_html(body)

    # It used to be `hidden md:block` (mobile-hidden). The <footer> element itself
    # must no longer be gated behind a breakpoint, so it renders on mobile too.
    # Scope this to the opening tag's classes (inner content may use `hidden` for
    # unrelated reasons).
    [footer_tag] = Regex.run(~r/<footer[^>]*>/, footer)
    refute footer_tag =~ "hidden"
    # Centered, with the links laid out as a wrapping, centered row.
    assert footer =~ "text-center"
    assert footer =~ "justify-center"
  end

  test "the footer nav separates its links with middots, like the credit line", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)
    [nav] = Regex.run(~r{<nav.*?</nav>}s, footer_html(body))

    assert nav =~ "·"
  end

  defp footer_html(body) do
    [footer] = Regex.run(~r{<footer.*?</footer>}s, body)
    footer
  end
end
