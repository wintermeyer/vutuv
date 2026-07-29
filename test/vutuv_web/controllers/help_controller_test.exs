defmodule VutuvWeb.HelpControllerTest do
  use VutuvWeb.ConnCase, async: true

  # `/system/markdown` documents what a member may write in a post, and its
  # examples are rendered by the same code that renders a post. That is the
  # point of the page and the thing worth guarding: if the renderer ever stops
  # producing a labelled code block, a diff row or a footnote, this page stops
  # showing one, and these tests fail rather than the page quietly lying.
  #
  # The locale assertions are the standing German-render rule (see CLAUDE.md):
  # a plain English request would pass while every German visitor read English.

  alias Vutuv.Accounts.ReservedSlugs

  defp german(conn), do: put_req_header(conn, "accept-language", "de-DE,de;q=0.9")

  describe "GET /system/markdown" do
    test "is public and needs no login", %{conn: conn} do
      conn = get(conn, ~p"/system/markdown")

      assert html_response(conn, 200) =~ "Markdown"
    end

    test "renders in German for a German visitor", %{conn: conn} do
      html = conn |> german() |> get(~p"/system/markdown") |> html_response(200)

      assert html =~ "Text formatieren mit Markdown"
      assert html =~ "Fett, kursiv, durchgestrichen"
      assert html =~ "Fußnoten"
      refute html =~ "Bold, italics, strikethrough"
    end

    test "renders in English otherwise", %{conn: conn} do
      html = conn |> get(~p"/system/markdown") |> html_response(200)

      assert html =~ "Formatting text with Markdown"
      assert html =~ "Bold, italics, strikethrough"
    end

    test "its examples are really rendered, not described" do
      html = build_conn() |> get(~p"/system/markdown") |> html_response(200)

      # A code block with its language named and its tokens coloured …
      assert html =~ ~s(data-language="Elixir")
      assert html =~ ~s(<span class="hl-com">)
      # … a block that names its file (issue #1137) …
      assert html =~ ~s(data-title="app/Providers/AppServiceProvider.php")
      # … a diff, and a diff whose code is coloured (issue #1138) …
      assert html =~ ~s(diff-line diff-line--add)
      assert html =~ ~s(<code class="diff language-elixir">)
      # … a table, a quote and a footnote list.
      assert html =~ "<table>"
      assert html =~ "<blockquote>"
      assert html =~ ~s(<div class="footnotes">)
    end

    test "its German chrome is really German", %{conn: conn} do
      # `gettext.extract --merge` fuzzy-fills a new msgid with the translation
      # of whatever string it looks similar to, and it did exactly that here:
      # "Markdown help" arrived as "Markdown". Nothing fails the build over a
      # fuzzy entry, so the short labels get named in a test.
      html = conn |> german() |> get(~p"/system/markdown") |> html_response(200)

      assert html =~ "Auf dieser Seite"
      assert html =~ "Diese Seite als Markdown lesen"
    end

    test "the table of contents links to headings that exist on the page" do
      html = build_conn() |> get(~p"/system/markdown") |> html_response(200)

      assert html =~ ~s(<a href="#code")
      assert html =~ ~s(<h2 id="code">)
    end
  end

  describe "the Markdown sibling" do
    test "serves the raw file", %{conn: conn} do
      conn = get(conn, "/system/markdown.md")

      assert response(conn, 200) =~ "# Formatting text with Markdown"
      assert response_content_type(conn, :md) =~ "text/markdown"
    end

    test "serves the German file to a German visitor", %{conn: conn} do
      body = conn |> german() |> get("/system/markdown.md") |> response(200)

      assert body =~ "# Text formatieren mit Markdown"
    end
  end

  test "the page's own path is under /system, so it burns no handle" do
    refute "markdown" in ReservedSlugs.list()
  end

  describe "finding the page from where you write" do
    test "a form that says Markdown is supported also says where to look it up",
         %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html = html_response(get(conn, ~p"/settings/work_experiences/new"), 200)

      assert html =~ "Markdown is supported"
      assert html =~ ~s(href="/system/markdown")
      assert html =~ "Markdown help"
    end
  end
end
