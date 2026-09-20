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

  defp accept(conn, locale),
    do: put_req_header(conn, "accept-language", "#{locale}-#{String.upcase(locale)},#{locale}")

  # One row per served locale rather than a test per language: the render path is
  # locale-generic (`@bodies[page][locale]`), so what differs between the copies
  # is data, and three hand-written copies had left Italian with no coverage at
  # all while a fourth language cost two more. `{page title, a section heading}`
  # per page — the section heading is what catches a page that renders its title
  # from the right file and its body from another.
  #
  # Apostrophes are avoided in these substrings on purpose: the renderer escapes
  # `'` to `&#39;`, so a French or Italian sentence asserted verbatim fails on a
  # page that is perfectly correct.
  @pages %{
    "markdown" => %{
      "en" => {"Formatting text with Markdown", "Bold, italics, strikethrough"},
      "de" => {"Text formatieren mit Markdown", "Fett, kursiv, durchgestrichen"},
      "fr" => {"Mettre en forme un texte avec Markdown", "Notes de bas de page"},
      "it" => {"Formattare il testo con Markdown", "Grassetto, corsivo, barrato"}
    },
    "mastodon" => %{
      "en" => {"Using a Mastodon app", "The address to type"},
      "de" => {"Eine Mastodon-App benutzen", "Welche Adresse Sie eintippen"},
      "fr" => {"Utiliser une application Mastodon", "adresse à saisir"},
      "it" => {"Usare un", "indirizzo da digitare"}
    }
  }

  describe "GET /system/markdown" do
    test "is public and needs no login", %{conn: conn} do
      conn = get(conn, ~p"/system/markdown")

      assert html_response(conn, 200) =~ "Markdown"
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
      html = conn |> accept("de") |> get(~p"/system/markdown") |> html_response(200)

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
  end

  # Both pages in every language this installation serves. A page that renders in
  # the wrong language is not a broken page — it answers 200 and reads fine — so
  # nothing but an assertion per locale catches it, and the `.md` sibling is
  # asserted beside the HTML because the two read the same file through different
  # code paths (`@sources` raw vs `@bodies` rendered).
  for {page, by_locale} <- @pages, {locale, {title, section}} <- by_locale do
    describe "/system/#{page} in #{locale}" do
      test "renders that language, not English", %{conn: conn} do
        html =
          conn
          |> accept(unquote(locale))
          |> get("/system/#{unquote(page)}")
          |> html_response(200)

        assert html =~ unquote(title)
        assert html =~ unquote(section)
      end

      test "serves the same language as the raw .md", %{conn: conn} do
        body =
          conn |> accept(unquote(locale)) |> get("/system/#{unquote(page)}.md") |> response(200)

        assert body =~ "# " <> unquote(title)
      end
    end
  end

  # `fill_host/1` is one function for both pages and every locale, so this asks
  # it once rather than riding along on a per-language test. A page that still
  # said `{{host}}` would send every reader's Mastodon app nowhere, and
  # `{{issues}}` would point their bug report at a dead link.
  test "neither page ships a placeholder unsubstituted", %{conn: conn} do
    for page <- ~w(markdown mastodon) do
      html = conn |> get("/system/#{page}") |> html_response(200)

      refute html =~ "{{host}}"
      refute html =~ "{{issues}}"
    end

    assert conn |> get("/system/mastodon") |> html_response(200) =~ VutuvWeb.Endpoint.host()
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
