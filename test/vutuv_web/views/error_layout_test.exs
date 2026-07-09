defmodule VutuvWeb.ErrorLayoutTest do
  @moduledoc """
  The exception-rescued error path (`render_errors`) must produce a **complete,
  self-contained, styled** document, not the bare `.error-page` fragment that
  shipped to production as unstyled browser-default serif text (a 500 that read
  like a broken page).

  These render the error pages through the layout that is **actually
  configured** in `render_errors`, so setting `layout:` back to `false` (the
  regression) makes them fail. `error_html_test.exs` still covers the fragment
  itself; this file covers the document that wraps it.
  """
  use VutuvWeb.ConnCase, async: true

  alias VutuvWeb.ErrorHTML

  # Render an error page exactly the way Phoenix's RenderErrors plug does: the
  # configured error view + layout, at the matching status. Reading the layout
  # from config is the point - a `false` there yields a bare fragment and the
  # document assertions below fail.
  defp render_error(status) do
    layout = Application.get_env(:vutuv, VutuvWeb.Endpoint)[:render_errors][:layout]

    build_conn()
    |> Plug.Conn.put_status(status)
    # Pass the configured layout verbatim, exactly as RenderErrors does - so a
    # `false` there yields a bare fragment and the document assertions fail.
    |> Phoenix.Controller.put_layout(layout)
    |> Phoenix.Controller.put_view(html: ErrorHTML)
    |> Phoenix.Controller.render("#{status}.html", status: status)
    |> html_response(status)
  end

  test "render_errors wraps error pages in a layout, never `false`" do
    render_errors = Application.get_env(:vutuv, VutuvWeb.Endpoint)[:render_errors]
    assert render_errors[:layout] == [html: {VutuvWeb.LayoutHTML, :error}]
  end

  test "the 500 page is a complete HTML document, not a bare fragment" do
    body = render_error(500)

    assert body =~ ~r/<!doctype html>/i
    assert body =~ "<html"
    assert body =~ "<head>"
    assert body =~ "</body>"
  end

  test "the 500 page carries its own inline styling, independent of the asset pipeline" do
    body = render_error(500)

    # A 500 is exactly when /assets/app.css may be unavailable, so the styling
    # must travel with the page - including the error card and the
    # system-following dark mode.
    assert body =~ "<style"
    assert body =~ ".error-page"
    assert body =~ "prefers-color-scheme: dark"

    # No dependency on the (possibly broken) digested stylesheet.
    refute body =~ ~s(rel="stylesheet")
  end

  test "the 500 page looks like vutuv: brand wordmark, the message, and a way home" do
    body = render_error(500)

    assert body =~ "vutuv"
    assert body =~ "went wrong"
    assert body =~ ~s(href="/")
  end

  test "the styled shell also wraps the 404 and 413 error pages" do
    for status <- [404, 413] do
      body = render_error(status)
      assert body =~ ~r/<!doctype html>/i
      assert body =~ ".error-page"
    end
  end
end
