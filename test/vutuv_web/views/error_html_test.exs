defmodule VutuvWeb.ErrorHTMLTest do
  use VutuvWeb.ConnCase, async: true

  alias Phoenix.HTML.Safe
  alias VutuvWeb.ErrorHTML

  defp render_to_string(template) do
    ErrorHTML.render(template, %{})
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "renders 404.html" do
    assert render_to_string("404.html") =~ "Page not found"
  end

  test "render 500.html" do
    assert render_to_string("500.html") =~ "Something went wrong."
  end

  test "error pages link back home" do
    assert render_to_string("404.html") =~ ~s(href="/")
  end

  # An upload beyond Plug.Parsers' multipart cap raises before any controller
  # runs; the member uploading a too-big LinkedIn archive or photo deserves the
  # styled card, not the bare fallback text.
  test "renders 413.html as a styled page" do
    assert render_to_string("413.html") =~ "too large"
    assert render_to_string("413.html") =~ ~s(href="/")
  end

  # A defective form submission (a mangled multipart body, issue #1227) raises
  # in the endpoint before any controller runs, so no per-form message can
  # help; the member used to get the bare fallback words "Bad Request" with no
  # explanation and no way forward.
  test "renders 400.html as a styled page with retry guidance" do
    body = render_to_string("400.html")
    assert body =~ "could not read"
    assert body =~ "reload the page"
    assert body =~ ~s(href="https://github.com/wintermeyer/vutuv/issues")
    assert body =~ "exact time of the error"
    # The page hands the member the timestamp to quote in a report.
    assert body =~ ~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC/
    assert body =~ ~s(href="/")
  end

  # The one member this page is known to have failed browses in German; a
  # fuzzy-filled .po would ship confident nonsense while the English tests
  # stay green, so pin the German wording by name.
  test "renders 400.html in German" do
    Gettext.put_locale(VutuvWeb.Gettext, "de")
    body = render_to_string("400.html")
    assert body =~ "nicht lesen konnten"
    assert body =~ "laden Sie die Seite neu"
    assert body =~ "genaue Uhrzeit"
  end

  test "render any other" do
    assert ErrorHTML.render("505.html", []) =~
             "HTTP Version Not Supported"
  end
end
