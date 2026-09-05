defmodule VutuvWeb.ErrorHTMLTest do
  @moduledoc """
  The error cards themselves; `error_layout_test.exs` covers the document that
  wraps them.

  `async: false` because one test flips `:deploy_minutes`, which the sandbox
  does not roll back and the 500 card reads on every render — including the one
  `error_layout_test.exs` does. Nothing else in the app reads that key.
  """
  use VutuvWeb.ConnCase, async: false

  alias Phoenix.HTML.Safe
  alias Vutuv.Operator
  alias VutuvWeb.ErrorHTML

  defp render_to_string(template) do
    ErrorHTML.render(template, %{})
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # A 404 is the opposite of the 500 and has to say so: nothing is broken, the
  # address is simply not ours. "Page not found" alone is what a browser also
  # shows when a site is down.
  test "renders 404.html" do
    body = render_to_string("404.html")

    assert body =~ "This page does not exist"
    assert body =~ "site itself is running"
    assert body =~ "carries a typo"
    assert body =~ ~s(href="/")
  end

  test "renders 404.html in German" do
    Gettext.put_locale(VutuvWeb.Gettext, "de")
    body = render_to_string("404.html")

    assert body =~ "Diese Seite gibt es nicht"
    assert body =~ "Die Website läuft"
    assert body =~ "Tippfehler"
  end

  # A 500 knows nothing about its own cause, so the page names the two shapes
  # it can have — a fault, or a deploy in flight — puts a number on the wait
  # that follows from the second, and hands the visitor a way to report the
  # first: who to write to, plus the code and the minute for the log.
  test "render 500.html" do
    body = render_to_string("500.html")

    assert body =~ "offline right now"
    assert body =~ "fault in the software or a new version being installed"
    assert body =~ "takes up to 10 minutes"
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

    assert body =~ "Diese Website ist gerade offline."
    assert body =~ "Fehler in der Software"
    assert body =~ "bis zu 10 Minuten"
    assert body =~ "Fehlercode 500"
  end

  # The deploy takes as long as it takes on THIS installation — a number typed
  # into a translation would promise every other installation our pipeline.
  test "the wait it names is the configured one" do
    original = Application.fetch_env(:vutuv, :deploy_minutes)
    Application.put_env(:vutuv, :deploy_minutes, 25)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :deploy_minutes, was)
        :error -> Application.delete_env(:vutuv, :deploy_minutes)
      end
    end)

    assert render_to_string("500.html") =~ "takes up to 25 minutes"
  end

  # The plain card the three refusals with nothing to explain still share.
  test "renders 403.html" do
    body = render_to_string("403.html")

    assert body =~ "not allowed to view this page"
    assert body =~ ~s(href="/")
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
