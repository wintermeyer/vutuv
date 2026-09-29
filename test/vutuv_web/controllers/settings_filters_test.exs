defmodule VutuvWeb.SettingsFiltersTest do
  use VutuvWeb.ConnCase, async: true

  # `/settings/filters` renders its own error lines rather than going through
  # `error_tag`, so a refused pattern has to be translated and interpolated
  # there: it printed "should be at most %{count} character(s)" verbatim.

  defp refuse(conn, pattern, lang) do
    conn
    |> recycle()
    |> put_req_header("accept-language", lang)
    |> post(~p"/settings/filters", %{
      "content_filter" => %{"kind" => "keyword", "pattern" => pattern}
    })
    |> html_response(422)
  end

  test "a refused pattern names its limit instead of a placeholder", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    html = refuse(conn, String.duplicate("x", 300), "en")

    refute html =~ "%{count}"
    assert html =~ ~r/should be at most \d+ character/
  end

  test "the wildcard limit is spelled out", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    html = refuse(conn, "*a*b*c*d*e*f*", "en")

    refute html =~ "%{max}"
    assert html =~ ~r/at most \d+ wildcards/
  end

  test "the refusal is German on a German page", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    html = refuse(conn, "   ", "de-DE,de")

    refute html =~ "can&#39;t be blank"
    refute html =~ "can't be blank"
  end
end
