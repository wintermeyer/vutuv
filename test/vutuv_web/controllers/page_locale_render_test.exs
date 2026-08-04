defmodule VutuvWeb.PageLocaleRenderTest do
  @moduledoc """
  The logged-out landing page must render in **every** supported locale. A
  `.po` merge once duplicated the German consent sentence, and the template's
  hard `[a, b] = String.split(gettext(...))` raised on the extra placeholder -
  so vutuv.de 500ed for every German visitor while the English render (and a
  `?lang=de` request that still rendered English) stayed green and hid it.

  This drives the page through the real browser pipeline with an
  `Accept-Language` header, the way an actual visitor's browser sets the
  locale, and loops over the configured locales so a newly added language is
  covered automatically.
  """
  use VutuvWeb.ConnCase, async: true

  defp locales do
    Application.get_env(:vutuv, VutuvWeb.Endpoint)[:locales]
  end

  test "the landing page renders (200) in every supported locale", %{conn: conn} do
    for locale <- locales() do
      html =
        conn
        |> put_req_header("accept-language", locale)
        |> get(~p"/")
        |> html_response(200)

      # The consent line (the block that raised) actually rendered its links.
      assert html =~ ~s(href="/nutzungsbedingungen")
      assert html =~ ~s(href="/datenschutzerklaerung")
    end
  end

  test "German is served on an Accept-Language: de-DE header (the reported case)", %{conn: conn} do
    html =
      conn
      |> put_req_header("accept-language", "de-DE,de;q=0.9")
      |> get(~p"/")
      |> html_response(200)

    # Proves it is the *German* render that no longer crashes, not an English
    # fallback masking the bug.
    assert html =~ "Mit der Registrierung akzeptieren Sie"
  end

  test "the gender question is really translated, not fuzzy-filled", %{conn: conn} do
    # `mix gettext.extract --merge` fills a brand-new msgid with the translation
    # of whatever existing string it looks similar to, flags it `fuzzy`, and
    # fails no build — so a German page can ship confident nonsense while every
    # English assertion stays green. This field walked straight into it:
    # "Diverse" came back as "Trennlinie" and "Male" as "Maltesisch". One-word
    # labels are what that matcher gets wrong, so every one of them is asserted
    # here by name in the German render.
    html =
      conn
      |> put_req_header("accept-language", "de-DE,de;q=0.9")
      |> get(~p"/")
      |> html_response(200)

    gender = fieldset_text(html, "#signup-gender")

    assert gender =~ "Geschlecht"
    assert gender =~ "Weiblich"
    assert gender =~ "Männlich"
    assert gender =~ "Divers"
    assert gender =~ "Keine Angabe"

    # The two labels that were fuzzy-filled with unrelated words. Naming them
    # keeps the regression identifiable if anyone re-runs the merge and takes
    # the suggestion.
    refute gender =~ "Trennlinie"
    refute gender =~ "Maltesisch"
  end

  # The text of one fieldset on the rendered page. `query/2`, never `filter/2`:
  # on a whole document `filter/2` only matches root nodes, so it would return
  # an empty set and make every refute below pass without looking at anything.
  defp fieldset_text(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
  end

  test "split_marker/2 is total, so a botched translation can never 500 the page" do
    # Correct: one split into before/after.
    assert VutuvWeb.UI.split_marker("a {x} b", "{x}") == {"a ", " b"}
    # Doubled placeholder (the corruption that shipped): still exactly two parts.
    assert VutuvWeb.UI.split_marker("a {x} b {x} c", "{x}") == {"a ", " b {x} c"}
    # Missing placeholder: no raise, the whole string is the "before".
    assert VutuvWeb.UI.split_marker("no marker here", "{x}") == {"no marker here", ""}
  end
end
