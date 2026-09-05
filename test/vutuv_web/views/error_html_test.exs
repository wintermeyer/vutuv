defmodule VutuvWeb.ErrorHTMLTest do
  use VutuvWeb.ConnCase, async: true

  alias Phoenix.HTML.Safe
  alias Vutuv.Operator
  alias VutuvWeb.ErrorHTML

  defp render_to_string(template) do
    ErrorHTML.render(template, %{})
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "renders 404.html" do
    assert render_to_string("404.html") =~ "Page not found"
  end

  # A 500 knows nothing about its own cause and cannot tell how long the site
  # has been broken, so the page's whole job is to say that and hand the
  # visitor a way to report it: who to write to, plus the code and the minute
  # that let the operator find it in the log.
  test "render 500.html" do
    body = render_to_string("500.html")

    assert body =~ "broken right now"
    assert body =~ "try again in a few minutes"
    assert body =~ "quote the error code 500"
    assert body =~ ~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC/
    # That the name comes from config rather than from a template is proved
    # where the key can safely be flipped (`service_worker_test.exs`, sync).
    assert body =~ "mailto:" <> Operator.contact_email()
    # The subject arrives prefilled, so most people need copy nothing at all.
    assert body =~ "subject=Error%20500%20on%20"
  end

  # The German render is the one real visitors get, and a fuzzy-filled .po
  # would ship confident nonsense while every English assertion above stays
  # green.
  test "renders 500.html in German" do
    Gettext.put_locale(VutuvWeb.Gettext, "de")
    body = render_to_string("500.html")

    assert body =~ "Störung"
    assert body =~ "in ein paar Minuten"
    assert body =~ "Fehlercode 500"
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
