defmodule VutuvWeb.LandingPageTest do
  @moduledoc """
  The logged-out landing page's marketing copy: the hero's three claims, and
  the two blocks under the sign-up form — six promises anybody can read without
  knowing a technical word, then one short section for the technically minded.

  This file is all render assertions and holds no fixtures: nothing under the
  form depends on a member or a post. Two earlier shapes of that block are
  gone and asserted against below, because both are recurring ideas: a wall of
  real, current posts behind a cached snapshot and an embedded LiveView, and
  four fanned screenshot decks of a profile, the CV builder, the Arbeitszeugnis
  review and the Fediverse feed. The wall cost a socket on the most requested
  page in the app; the decks, with the three product sections around them,
  made the page a feature catalogue nobody outside the project read to the end
  (Stefan, 2026-09-06).

  Anything that depends on an installation switch lives in
  `VutuvWeb.LandingConfigurationTest` instead, which is `async: false` because
  it flips global application env.
  """
  use VutuvWeb.ConnCase, async: true

  defp landing(conn), do: conn |> get(~p"/") |> html_response(200)

  # vutuv is a German site and ConnTest defaults to English, so a German render
  # is its own request: a fuzzy-filled or missing msgstr is invisible otherwise
  # (see the locale rule in CLAUDE.md).
  defp landing_de(conn) do
    conn |> put_req_header("accept-language", "de-DE,de") |> landing()
  end

  defp at(html, marker), do: :binary.match(html, marker) |> elem(0)

  describe "the landing page" do
    # The one founder quote. It used to be a split test between this and a
    # warmer invitation ("Genervt von LinkedIn? Dann mal herein in die gute
    # Stube."), which Stefan ended in favour of the dry one (2026-09-07); the
    # rotation and everything that counted it are gone with it. Asserted in
    # both languages because a missing msgstr renders the English msgid on the
    # German page, which is invisible to an English-only check.
    test "carries one headline, the same one for everybody", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "„LinkedIn nervt. vutuv nicht.“"
      refute html =~ "gute Stube"

      assert landing(build_conn()) =~ "LinkedIn is annoying. vutuv is not."
    end

    # The three claims beside the quote: whoever agrees that LinkedIn is
    # annoying wants to know what they have to retype, how it feels, and what it
    # will cost them later. Asserted as the rendered German literals for the
    # reason the whole file renders in German — an untranslated or fuzzy-filled
    # msgstr shows up perfectly in an English render, and the short ones
    # ("Schnell.") are the likeliest to be fuzzy-matched.
    #
    # Three claims and nothing else: the explaining half-sentences two of them
    # carried are refused below (Stefan, 2026-09-07), because a claim that
    # needs a second sentence to stand up is not a claim.
    test "the hero lists what a LinkedIn refugee gets", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "Einfacher LinkedIn-Profil-Import."
      assert html =~ "Schnell."
      assert html =~ "Keine bezahlten Premium-Accounts."

      refute html =~ "Ihr LinkedIn-Profil kann mitkommen."
      refute html =~ "Das will doch eh keiner."
      refute html =~ "rattenschnell"
      refute html =~ "ridiculously fast"

      # Deliberately statements, not links: /import/linkedin needs an account,
      # so a logged-out click would trade the sign-up form for the login page.
      refute html =~ ~s(href="/import/linkedin")
    end

    # The six promises, each a card with a title and a sentence or two, and
    # every one of them readable by somebody who has never heard the word
    # "Fediverse". Asserted as German literals for the reason the hero test is,
    # and by name, so a seventh card or a renamed one is a decision and not a
    # drift.
    test "makes six promises anybody can read", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "Was vutuv anders macht"

      for key <- ~w(organizations family fast simple leave data) do
        assert length(elements(html, "[data-landing-promise=#{key}]")) == 1
      end

      assert length(elements(html, "[data-landing-promise]")) == 6

      assert html =~ "Menschen und Organisationen"
      assert html =~ "Für Familie und Arbeitsplatz geeignet"
      assert html =~ "Schnell, auch bei schlechtem Netz"
      # Not "Einfach" alone: the hero's "Einfacher LinkedIn-Profil-Import."
      # contains it.
      assert html =~ "vutuv richtet sich an jeden."
      assert html =~ "Ausprobieren, und gehen, wenn Sie wollen"
      assert html =~ "Ihre Daten bleiben hier"

      # Fast is the claim; the data-saving mode is what backs it for somebody
      # on a poor connection, named by the same word the sign-up box and
      # /settings/bandwidth use, so the reader recognizes the switch later.
      assert html =~ "Datensparmodus"
    end

    # The order a person has to follow and nobody explains: your own account
    # first, then a page for the organization, then the colleagues who help
    # run it. Three numbered steps drawn as a row, and the organization is not
    # only a company.
    test "spells out the person-then-organization order as three steps", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "Sie legen als Person Ihr eigenes Konto an."
      assert html =~ "Eingeloggt legen Sie dann die Seite Ihrer Organisation an"
      assert html =~ "Behörde oder jede andere Gruppe"
      assert html =~ "Kollegen dazu"

      steps = elements(html, "ol[data-landing-steps] li")
      assert length(steps) == 3
      assert Enum.map(steps, &text_of(&1 |> LazyHTML.to_html(), "span")) == ~w(1 2 3)
    end

    # The bento (Stefan's pick of seven, 2026-09-06): the organization tile is
    # the wide one, the data tile the tall dark one, and the pictogram is on
    # every tile. Asserted on the grid classes because that is the whole
    # difference between this and six equal cards.
    test "lays the six out as a bento with the organization tile widest", %{conn: conn} do
      html = landing(conn)

      [org] = elements(html, "[data-landing-promise=organizations]")
      assert attribute(org, "class") =~ "md:col-span-4"
      assert attribute(org, "class") =~ "bg-brand-50"

      [data] = elements(html, "[data-landing-promise=data]")
      assert attribute(data, "class") =~ "md:row-span-2"
      assert attribute(data, "class") =~ "bg-brand-900"

      assert length(elements(html, "[data-landing-promise] [data-promise-icon] svg")) == 6
    end

    # The family-friendly promise is the house rules, a page anybody can open,
    # in the community page's own words. Deliberately NOT the picture scan:
    # it runs, but "every picture is checked before anyone sees it" is a
    # guarantee this page must not give (Stefan, 2026-09-06).
    test "says what family-friendly means and links the house rules", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "Zwölfjährigen"
      assert html =~ ~s(href="/community")
      refute html =~ "wird geprüft"
    end

    # Both directions of the try-it-and-leave promise, and the check behind the
    # second: deletion cascades the addresses away, so the door really is open
    # again (add_cascade_deletes_on_user_associations).
    test "promises the way out as plainly as the way in", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "löschen Sie es selbst"
      assert html =~ "Niemand fragt, warum"
      assert html =~ "jederzeit wieder willkommen"
    end

    # Three of the four data claims are properties of the software and hold on
    # every installation; where the servers stand is the operator's alone and
    # is covered in the configuration test.
    test "says what happens to the data, in plain words", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "eigenen Servern in Deutschland"
      assert html =~ "keiner fremden Cloud"
      assert html =~ "Keine Cookies von Dritten"
      assert html =~ "ein einziges Cookie"
    end

    # The technical section: last, always visible, four lines. Whoever does not
    # care is long past it at the form; whoever does gets the Fediverse, the
    # source code, the machine formats and the sign-in options in one place,
    # with the links that let them check.
    test "closes with one section for the technically minded", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "data-landing-technical"
      assert html =~ "Für Technikinteressierte"
      assert html =~ "Mit oder ohne Fediverse"
      assert html =~ "Mastodon"
      assert html =~ "Open Source"
      assert html =~ "MIT-Lizenz"
      assert html =~ "Lesbar für Maschinen"
      assert html =~ "Anmelden ohne Passwort"
      assert html =~ "Passkey"

      assert html =~ ~s(href="/developers")
      assert html =~ ~s(href="/llms.txt")
      assert html =~ Vutuv.SourceRepo.url()
    end

    # The page's argument, in order: the form, then what anybody can read, then
    # what only some people want to know. A technical line above a plain one
    # is exactly what puts a non-technical visitor to sleep.
    test "the form comes first, the promises next, the technical section last", %{conn: conn} do
      html = landing(conn)

      assert at(html, "registration-form") < at(html, "data-landing-promises")
      assert at(html, "data-landing-promises") < at(html, "data-landing-technical")
    end

    # Nothing technical leaks into the block for everybody: the words that
    # need a definition live in the technical section only.
    test "keeps the technical vocabulary out of the promises", %{conn: conn} do
      promises = conn |> landing_de() |> text_of("[data-landing-promises]")

      for word <- [
            "Fediverse",
            "Mastodon",
            "Markdown",
            "JSON",
            "API",
            "Open Source",
            "Passkey",
            "MIT-"
          ] do
        refute promises =~ word, "#{word} is in the promises block, not the technical one"
      end
    end

    # The screenshot decks and the three product sections that carried them
    # are gone and stay gone (the moduledoc says why).
    test "shows no screenshots and no product sections", %{conn: conn} do
      html = landing_de(conn)

      refute html =~ "/images/landing-"
      refute html =~ "-shots"
      refute html =~ "Arbeitszeugnis"
      refute html =~ "Lebenslauf, fertig"
      refute html =~ "JSON Resume"
      refute html =~ "Was vutuv kann"
    end

    # The wall of real posts was removed for what it cost: a LiveView per visit
    # plus a cached snapshot behind it, on the page that greets every crawler.
    # Asserted rather than merely deleted, because "add a bit of life to the
    # front page" is a recurring idea and this is where the answer lives.
    test "opens no socket of its own for a post wall", %{conn: conn} do
      html = landing(conn)

      refute html =~ "data-showcase-posts"
      refute html =~ "landing-posts"
      refute html =~ "post-carousel"
    end

    # The landing page is rendered from two actions: `index`, and the rejected
    # sign-up, which shows the identical screen with the errors on it. Assigning
    # the examples in `index` alone 500ed every mistyped form.
    test "a rejected sign-up re-renders the page with its blocks", %{conn: conn} do
      html =
        conn
        |> post(~p"/new_registration", user: %{"first_name" => "No Email"})
        |> html_response(422)

      assert html =~ "data-landing-promises"
      assert html =~ "data-landing-technical"
    end
  end

  describe "German rendering" do
    # The short labels are the ones `gettext.extract --merge` fuzzy-fills with
    # something unrelated ("Job applications" once came back as "Ihre
    # Anwendungen", i.e. software), so the two headings the other tests do not
    # already assert by name are asserted here.
    test "the remaining headings are German", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "Wenn Sie es genau wissen wollen"
      assert html =~ "Neugierig? Schauen Sie sich einmal das Profil vom vutuv-Gründer"
      assert html =~ "Mit oder ohne eigenen vutuv-Account."
    end
  end
end
