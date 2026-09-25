defmodule VutuvWeb.LandingPageTest do
  @moduledoc """
  The logged-out landing page's marketing copy: the hero's quote, sentence and
  three claims, and under the sign-up form the questions a visitor has before
  signing up, each answered in a sentence or two, open on the page.

  This file is all render assertions and holds no fixtures: nothing under the
  form depends on a member or a post. Three earlier shapes of that block are
  gone and asserted against below, because all three are recurring ideas: a
  wall of real, current posts behind a cached snapshot and an embedded
  LiveView; four fanned screenshot decks of a profile, the CV builder, the
  Arbeitszeugnis review and the Fediverse feed; and six promise tiles with a
  "for the technically minded" section after them. The wall cost a socket on
  the most requested page in the app; the decks, with the three product
  sections around them, made the page a feature catalogue nobody outside the
  project read to the end (Stefan, 2026-09-06); the tiles were our claims
  without the visitor's question in front of them, and half of them
  ("Simple", a how-to for organization pages) were no reason to join
  (Stefan, 2026-09-25).

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

  defp faq_keys(html) do
    html
    |> elements("[data-landing-faq-entry]")
    |> Enum.map(&attribute(&1, "data-landing-faq-entry"))
  end

  # The heading as a reader sees it: the short sentences sit in spans of their
  # own, so the markup no longer holds the quote as one string.
  defp headline(html), do: html |> text_of("h1") |> String.replace(~r/\s+/u, " ")

  describe "the landing page" do
    # The one founder quote. It used to be a split test between this and a
    # warmer invitation ("Genervt von LinkedIn? Dann mal herein in die gute
    # Stube."), which Stefan ended in favour of the dry one (2026-09-07); the
    # rotation and everything that counted it are gone with it. Asserted in
    # both languages because a missing msgstr renders the English msgid on the
    # German page, which is invisible to an English-only check.
    test "carries one headline, the same one for everybody", %{conn: conn} do
      html = landing_de(conn)

      assert headline(html) == "„LinkedIn nervt. vutuv nicht.“"
      refute html =~ "gute Stube"

      assert headline(landing(build_conn())) == "“LinkedIn is annoying. vutuv is not.”"
    end

    # On a phone the German quote broke between "vutuv" and "nicht". A sentence
    # of at most two words is kept on one line; a longer one is left to the
    # browser. Rendered in every locale, because only the catalog knows how
    # many words each sentence has: French and Italian keep their second
    # sentence alone, and French glues its closing « » » to it.
    for {locale, glued} <- [
          {"de-DE,de", ["„LinkedIn nervt.", "vutuv nicht.“"]},
          {"en", []},
          {"fr-FR,fr", ["vutuv non. »"]},
          {"it-IT,it", ["vutuv no.”"]}
        ] do
      test "keeps the headline's short sentences whole (#{locale})", %{conn: conn} do
        html = conn |> put_req_header("accept-language", unquote(locale)) |> landing()

        kept = html |> elements("h1 .whitespace-nowrap") |> Enum.map(&LazyHTML.text/1)
        assert kept == unquote(glued)

        heading = headline(html)
        assert heading =~ ~r/[.!?] \S/u, "the sentences must still be apart: #{heading}"
      end
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

    # The one sentence saying what vutuv is, in the hero under the signature.
    # The quote alone says only that vutuv is like LinkedIn without the
    # annoyance, which tells a visitor who never used LinkedIn nothing.
    test "the hero says in one sentence what vutuv is", %{conn: conn} do
      html = landing_de(conn)

      assert html =~
               "Ein berufliches Netzwerk für Menschen und Organisationen (Firmen, Behörden, Vereine, Universitäten …)."

      assert at(html, "Ein berufliches Netzwerk") < at(html, "data-hero-points")
    end

    # Nine questions somebody has BEFORE signing up, each answered in a
    # sentence or two, all open on the page: a collapsed block reads as
    # something to hide, and a FAQ that grows past what a visitor asks before
    # joining is the feature catalogue this replaced. Asserted by key, so a
    # tenth question or a renamed one is a decision and not a drift, and as
    # German literals for the reason the hero test gives.
    test "answers nine questions anybody asks before signing up", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "Häufige Fragen"

      assert faq_keys(html) ==
               ~w(price public data linkedin organizations fediverse open_source api delete)

      assert html =~ "Was kostet vutuv?"
      assert html =~ "Nichts. Es gibt keine bezahlten Premium-Accounts"
      assert html =~ "Kann ich mir Profile und Beiträge auf vutuv ansehen, ohne mich anzumelden?"
      assert html =~ "Wo liegen meine Daten?"
      assert html =~ "eigenen Servern in Deutschland"
      assert html =~ "ein einziges Cookie"
      assert html =~ "Kann ich mein LinkedIn-Profil mitnehmen?"
      assert html =~ "Wie bekommt meine Organisation"
      assert html =~ "Admin oder Redaktion"
      assert html =~ "Was hat vutuv mit dem Fediverse zu tun?"
      assert html =~ "Ist vutuv Open Source?"
      assert html =~ "MIT-Lizenz"
      assert html =~ "Gibt es eine API?"
      assert html =~ "Kann ich mein Konto wieder löschen?"
      assert html =~ "Niemand fragt, warum"

      refute html =~ "<details"
    end

    # The links that let a reader check an answer: the example profile, its
    # Markdown sibling, the source code. The deletion answer names the path
    # and deliberately does not link it, and the LinkedIn answer links
    # nothing: both pages need a login, so a logged-out click would trade the
    # sign-up form for the login page.
    test "links what can be checked and names the settings path unlinked", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ ~s(href="https://vutuv.de/wintermeyer")
      assert html =~ ~s(href="https://vutuv.de/wintermeyer.md")
      assert html =~ Vutuv.SourceRepo.url()

      assert html =~ "unter /settings/delete"
      refute html =~ ~s(href="/settings/delete")
      refute html =~ ~s(href="/import/linkedin")
    end

    # A crawler reads the same questions as a FAQPage block, built from the
    # list the page renders, so the two cannot drift.
    test "carries the questions as FAQPage JSON-LD mirroring the page", %{conn: conn} do
      html = landing_de(conn)

      faq = json_ld(html, "FAQPage")
      questions = Enum.map(faq["mainEntity"], & &1["name"])

      assert questions ==
               html
               |> elements("[data-landing-faq-entry] h3")
               |> Enum.map(&String.trim(LazyHTML.text(&1)))

      [price | _] = faq["mainEntity"]
      assert price["acceptedAnswer"]["@type"] == "Answer"
      assert price["acceptedAnswer"]["text"] =~ "Premium-Accounts"

      open_source = Enum.find(faq["mainEntity"], &(&1["name"] == "Ist vutuv Open Source?"))
      assert open_source["acceptedAnswer"]["url"] == Vutuv.SourceRepo.url()
    end

    # The page's argument, in order: the form, then the questions.
    test "the form comes first, the questions after", %{conn: conn} do
      html = landing(conn)

      assert at(html, "registration-form") < at(html, "data-landing-faq")
    end

    # The promise tiles, the screenshot decks and the product sections that
    # carried them are gone and stay gone (the moduledoc says why).
    test "shows no promise tiles, no screenshots and no product sections", %{conn: conn} do
      html = landing_de(conn)

      refute html =~ "data-landing-promise"
      refute html =~ "data-landing-technical"
      refute html =~ "Was vutuv anders macht"
      refute html =~ "Für Technikinteressierte"
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
    test "a rejected sign-up re-renders the page with its questions", %{conn: conn} do
      html =
        conn
        |> post(~p"/new_registration", user: %{"first_name" => "No Email"})
        |> html_response(422)

      assert html =~ "data-landing-faq"
      assert "delete" in faq_keys(html)
    end
  end

  describe "the teaser video" do
    # A browser takes the first <source> whose `media` matches and whose type
    # it can play. So a phone (below `md`) finds the 9:16 cut first, everybody
    # else the 16:9 one, and each comes as AV1 first, H.264 as the fallback
    # (Safari only claims AV1 where the hardware decodes it). Nothing loads
    # before a click (`preload="none"`, no autoplay), because the page promises
    # "Fast." and is the most requested one in the app.
    test "offers a portrait cut to phones and a landscape one to the rest, AV1 first",
         %{conn: conn} do
      html = landing_de(conn)
      [video] = elements(html, "video#landing-teaser")

      assert LazyHTML.attribute(video, "preload") == ["none"]
      assert LazyHTML.attribute(video, "autoplay") == []
      assert LazyHTML.attribute(video, "poster") == ["/images/teaser/vutuv-teaser-de.avif"]

      sources =
        video
        |> LazyHTML.query("source")
        |> Enum.map(&{attribute(&1, "src"), attribute(&1, "media"), attribute(&1, "type")})

      phone = "(max-width: 767px)"

      assert sources == [
               {"/images/teaser/vutuv-teaser-de-portrait.av1.mp4", phone,
                "video/mp4; codecs=av01.0.05M.08"},
               {"/images/teaser/vutuv-teaser-de-portrait.mp4", phone, "video/mp4"},
               {"/images/teaser/vutuv-teaser-de.av1.mp4", "", "video/mp4; codecs=av01.0.04M.08"},
               {"/images/teaser/vutuv-teaser-de.mp4", "", "video/mp4"}
             ]
    end

    # The hero is too narrow to watch a film in, so it shows the poster as a
    # play button, and the video itself sits in a dialog that button opens
    # (large on a desktop). The dialog starts it on opening and stops it on
    # closing (`data-play-on-open`, the modal helper in app.js).
    test "plays the video in a dialog the poster in the hero opens", %{conn: conn} do
      html = landing_de(conn)

      [button] = elements(html, ~s(button[data-modal-open="landing-teaser-dialog"]))
      assert attribute(button, "aria-label") == "Video abspielen"

      assert button |> LazyHTML.query("img") |> LazyHTML.attribute("src") ==
               ["/images/teaser/vutuv-teaser-de.avif"]

      assert [_] =
               elements(
                 html,
                 "dialog#landing-teaser-dialog video#landing-teaser[data-play-on-open]"
               )

      assert [_] = elements(html, "dialog#landing-teaser-dialog [data-modal-close]")
    end

    # The page plays half the master's resolution; the full one is one click
    # away in a bar UNDER the film, never over it: "Quality: Standard | HD",
    # the chosen one pressed. A lone "HD" pill on the picture read as a logo or
    # a badge rather than a control. Choosing swaps every source to its
    # `data-hd-src` (the helper in app.js) and carries on where it was.
    test "offers Standard and HD as a labelled choice under the film", %{conn: conn} do
      html = landing_de(conn)

      [bar] = elements(html, "dialog#landing-teaser-dialog [data-video-bar]")
      assert LazyHTML.text(bar) =~ "Qualität"

      choices =
        bar
        |> LazyHTML.query(~s(button[data-video-quality="landing-teaser"]))
        |> Enum.map(
          &{attribute(&1, "data-quality"), String.trim(LazyHTML.text(&1)),
           attribute(&1, "aria-pressed")}
        )

      assert choices == [{"sd", "Standard", "true"}, {"hd", "HD", "false"}]

      # the bar, with the close button, sits beside the video, not inside it
      assert [] = elements(html, "video#landing-teaser [data-video-bar]")

      assert [_] =
               elements(html, "dialog#landing-teaser-dialog [data-video-bar] [data-modal-close]")

      hd =
        html |> elements("video#landing-teaser source") |> Enum.map(&attribute(&1, "data-hd-src"))

      # the phone plays its cut full screen, where the toggle is out of reach
      assert hd == [
               "",
               "",
               "/images/teaser/vutuv-teaser-de.hd.av1.mp4",
               "/images/teaser/vutuv-teaser-de.hd.mp4"
             ]
    end

    # Two cuts: every German browser gets the German one, whatever its region.
    for locale <- ["de-AT,de;q=0.9", "de-CH"] do
      test "shows the German cut to #{locale}", %{conn: conn} do
        html = conn |> put_req_header("accept-language", unquote(locale)) |> landing()

        assert html =~ ~s(src="/images/teaser/vutuv-teaser-de.av1.mp4")
        refute html =~ "vutuv-teaser-en"
      end
    end

    # And every other language, or none at all, the English one.
    for locale <- ["en", "en-GB,en;q=0.9,de;q=0.8", "fr-FR,fr", "es-ES,es", nil] do
      test "shows the English cut to #{inspect(locale)}", %{conn: conn} do
        conn =
          if unquote(locale),
            do: put_req_header(conn, "accept-language", unquote(locale)),
            else: conn

        html = landing(conn)

        assert html =~ ~s(src="/images/teaser/vutuv-teaser-en.av1.mp4")
        refute html =~ "vutuv-teaser-de"
      end
    end
  end
end
