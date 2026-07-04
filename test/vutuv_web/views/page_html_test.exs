defmodule VutuvWeb.PageHTMLTest do
  use VutuvWeb.ConnCase, async: true

  test "GET /impressum renders a placeholder until the operator writes one", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)

    assert body =~ "not published this page yet"
    # The company name itself stays in the shared footer, so probe the street.
    refute body =~ "Johannes-Müller-Str."
  end

  test "GET /impressum renders the stored operator identity", %{conn: conn} do
    # A single newline is a hard line break (breaks: true, like the
    # newsletter renderer) — the natural way to write an address block.
    {:ok, _page} =
      Vutuv.Legal.upsert_page("impressum", %{
        body: "**Wintermeyer Consulting**\nJohannes-Müller-Str. 10"
      })

    body = conn |> get(~p"/impressum") |> html_response(200)

    assert body =~ "Wintermeyer Consulting"
    assert body =~ "Johannes-Müller-Str. 10"
    # The address lines break, and no raw markup leaks as escaped text.
    assert body =~ ~r|Consulting</strong>\s*<br|
    refute body =~ "&lt;br"
  end
end
