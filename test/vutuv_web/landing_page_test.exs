defmodule VutuvWeb.LandingPageTest do
  @moduledoc """
  The logged-out landing page's marketing copy: the hero's import pill, and the
  examples block under the sign-up form with its static screenshots of a
  profile, of the CV builder and of the Arbeitszeugnis review, the feature list,
  and the data-protection promises.

  Every example on the page is a picture, which is why this file is all render
  assertions and holds no fixtures. A wall of real, current posts used to sit
  between the profile block and the Fediverse block, with a context
  (`Vutuv.Landing`), a snapshot cache and an embedded LiveView behind it; it was
  removed for what it cost on the most requested page in the app, and the tests
  that covered its ranking, its windows and its carousel went with it.

  Anything that depends on an installation switch lives in
  `VutuvWeb.LandingConfigurationTest` instead, which is `async: false` because
  it flips global application env.
  """
  use VutuvWeb.ConnCase, async: true

  alias VutuvWeb.PageHTML

  defp landing(conn), do: conn |> get(~p"/") |> html_response(200)

  # vutuv is a German site and ConnTest defaults to English, so a German render
  # is its own request: a fuzzy-filled or missing msgstr is invisible otherwise
  # (see the locale rule in CLAUDE.md).
  defp landing_de(conn) do
    conn |> put_req_header("accept-language", "de-DE,de") |> landing()
  end

  # Every <img> of a screenshot deck, as whole tags.
  #
  # Matching whole tags rather than splitting on "<img": a split fragment runs
  # up to the NEXT img, which once swallowed a following <picture>'s AVIF source
  # and counted one screenshot too many.
  defp shot_tags(html) do
    ~r|<img[^>]*>|
    |> Regex.scan(html)
    |> List.flatten()
    |> Enum.filter(&String.contains?(&1, "/images/landing-"))
  end

  describe "the landing page" do
    # The three claims beside the quote, both halves of each: whoever agrees that
    # LinkedIn is annoying wants to know what they have to retype, how it feels,
    # and what it will cost them later. Asserted as the rendered German literals
    # for the reason the whole file renders in German — an untranslated or
    # fuzzy-filled msgstr shows up perfectly in an English render, and the
    # short ones ("Schnell.") are the likeliest to be fuzzy-matched.
    test "the hero lists what a LinkedIn refugee gets", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "Einfacher Profilimport."
      assert html =~ "Ihr LinkedIn-Profil kann mitkommen."
      assert html =~ "Schnell."
      assert html =~ "vutuv ist einfach rattenschnell."
      assert html =~ "Keine bezahlten Premium-Accounts."
      assert html =~ "Das will doch eh keiner."

      # Deliberately statements, not links: /import/linkedin needs an account,
      # so a logged-out click would trade the sign-up form for the login page.
      refute html =~ ~s(href="/import/linkedin")
    end

    # Static pictures, not live rows: nobody has to agree to being on the front
    # page, and there is no member whose rename or departure could break it.
    test "shows the profile screenshots", %{conn: conn} do
      html = landing(conn)

      assert html =~ "data-profile-shots"
      assert html =~ "/images/landing-profile-overview.avif"
      assert html =~ "/images/landing-profile-cv.avif"
      assert html =~ "/images/landing-profile-links.avif"
    end

    # The fan is a marketing gesture and a phone has no room for it: three
    # tilted cards at 390px would be three unreadable slivers. Every tilt,
    # overlap and stacking class therefore has to be md:-scoped.
    test "the fanned deck stays a plain stack below md", %{conn: conn} do
      html = landing(conn)

      # Matched generically and counted against the catalog, so a new deck is
      # covered the moment it is added rather than when somebody remembers to
      # extend a regex here.
      decks =
        Regex.scan(~r/<div\s+data-([a-z]+)-shots\s+class="([^"]+)"/, html,
          capture: :all_but_first
        )

      assert Enum.map(decks, fn [key, _] -> String.to_existing_atom(key) end) ==
               PageHTML.shot_decks()

      assert Enum.all?(decks, fn [_, d] -> not (d =~ ~r/(^|\s)(flex-row|justify-center)/) end)

      figures =
        html
        |> String.split("<figure")
        |> Enum.filter(&String.contains?(&1, "/images/landing-"))

      for figure <- figures,
          [classes] = Regex.run(~r/class="([^"]+)"/, figure, capture: :all_but_first),
          klass <- String.split(classes),
          klass =~ ~r/rotate|^-?m[lrbt]-|^z-/ do
        assert String.starts_with?(klass, "md:"),
               "#{klass} tilts or overlaps the deck on a phone too"
      end
    end

    # Both halves of the promise: the checklist you decide with, and the
    # document that comes out of it.
    test "shows the CV builder and the CV it produces", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "data-career-shots"
      assert html =~ "/images/landing-cv-builder.avif"
      assert html =~ "/images/landing-cv-print.avif"
      assert html =~ "Ihr Lebenslauf, fertig zum Verschicken"
      assert html =~ "JSON Resume"
    end

    test "shows the employment-reference review", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "data-reference-shots"
      assert html =~ "/images/landing-reference-list.avif"
      assert html =~ "/images/landing-reference-check.avif"
      assert html =~ "Was in Ihrem Arbeitszeugnis wirklich steht"
    end

    # The two closing lines of that section, and the reason it is a section of
    # its own. The first is quoted from the feature page so the two surfaces
    # cannot state the storage promise differently; the second is the boundary
    # the analysis prompt itself enforces (§ 2 RDG), so the front page must not
    # promise past it.
    test "says where the reference stays and what the review is not", %{conn: conn} do
      html = landing_de(conn)

      # Asserted as the rendered German literal, not by calling
      # `check_location_heading/0` here: gettext's locale is per process, and
      # the test process is not the one that rendered the request, so the call
      # would answer in English and pass for the wrong reason.
      assert html =~ "Ihr Zeugnis bleibt auf unseren Servern in"
      assert html =~ "eigener Hardware"
      assert html =~ "keine Rechtsberatung"
    end

    # The Fediverse is the one thing nobody arrives already understanding, so it
    # gets its own section: the feed receiving posts from other networks, and
    # the page where a member subscribes to an account out there.
    test "explains how people talk to each other, in both directions", %{conn: conn} do
      html = landing(conn)

      assert html =~ "data-communication-shots"
      assert html =~ "/images/landing-feed-fediverse.avif"
      assert html =~ "/images/landing-fediverse-following.avif"
    end

    # Three of the four promises are properties of the software and hold on every
    # installation; the fourth is the operator's alone.
    test "closes with the data-protection promises", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "Fair und transparent"
      assert html =~ "eigenen Servern in Deutschland"
      assert html =~ "Keine Cookies von Dritten"
      assert html =~ "Ihre Daten bleiben Ihnen"
      assert html =~ "Jederzeit wieder gehen"
      # Checkable, not a nicety: deletion cascades the addresses away, so the
      # door really is open again.
      assert html =~ "gerne wiederkommen"
      # The card that backs the other four: they are claims, this is the check.
      assert html =~ "Open Source"
      assert html =~ "wie vutuv genau funktioniert"
    end

    # The page's argument, in order: this is what a profile looks like, this is
    # what you get out of one, and here is how far it reaches. The two
    # application sections sit that high on purpose, because they answer "what
    # do I get", which is the question a visitor decides on.
    test "the sections run in the catalog's order, features last", %{conn: conn} do
      html = landing(conn)

      at = fn marker -> :binary.match(html, marker) |> elem(0) end
      positions = Enum.map(PageHTML.shot_decks(), &at.("data-#{&1}-shots"))

      assert positions == Enum.sort(positions)
      assert List.last(positions) < at.("data-landing-features")
    end

    # AVIF only, by decision: a second format to keep pre-16.4 Safari served was
    # judged not worth the second set of files. Nine large images below the fold
    # of the busiest page in the app, so each is lazy and carries its own size
    # (the decks do not share one aspect ratio) and nothing shifts on load.
    test "every screenshot is a lazy, self-sizing AVIF with a real alt", %{conn: conn} do
      html = landing(conn)
      shots = shot_tags(html)

      assert length(shots) == 9
      assert Regex.scan(~r|src="/images/landing-[a-z-]+\.avif"|, html) |> length() == 9
      refute html =~ "landing-profile-overview.webp"
      refute html =~ "<picture>"

      assert Enum.all?(shots, &String.contains?(&1, ~s(loading="lazy")))
      assert Enum.all?(shots, fn shot -> shot =~ ~r/width="\d+"/ and shot =~ ~r/height="\d+"/ end)
      # An alt of substance, not a filename: for a reader who cannot see the
      # picture these blocks are nothing but their alt text.
      assert Enum.all?(shots, fn shot -> shot =~ ~r/alt="[^"]{60,}"/ end)
    end

    # `priv/static/` is gitignored, so a new screenshot renders perfectly in dev
    # and 404s in production unless somebody remembered `git add -f`. Nobody
    # should have to: this walks the catalog the page renders from and asks git.
    # It caught all four new shots of the Arbeitszeugnis/CV blocks.
    test "every screenshot in the catalog is in the git index" do
      tracked =
        System.cmd("git", ["ls-files", "priv/static/images"], cd: File.cwd!())
        |> elem(0)
        |> String.split("\n", trim: true)
        |> MapSet.new()

      missing =
        PageHTML.shot_decks()
        |> Enum.flat_map(&PageHTML.shot_list/1)
        |> Enum.map(fn shot -> "priv/static" <> (shot.src |> String.split("?") |> hd()) end)
        |> Enum.reject(&MapSet.member?(tracked, &1))

      assert missing == [],
             "these landing screenshots are not tracked by git and will 404 in " <>
               "production: #{Enum.join(missing, ", ")} (fix with `git add -f`)"
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

    # The installability rule: nothing on this page needs configuring, and a
    # brand-new installation with no members and no posts still gets the
    # screenshots and the feature list rather than a hole. The feature list is
    # our own copy, so it depends on no member at all.
    test "renders its own copy on a brand-new installation", %{conn: conn} do
      html = landing(conn)

      assert html =~ "data-profile-shots"
      assert html =~ "data-landing-features"
      assert html =~ "CV download"
    end

    # The landing page is rendered from two actions: `index`, and the rejected
    # sign-up, which shows the identical screen with the errors on it. Assigning
    # the examples in `index` alone 500ed every mistyped form.
    test "a rejected sign-up re-renders the page with its examples", %{conn: conn} do
      html =
        conn
        |> post(~p"/new_registration", user: %{"first_name" => "No Email"})
        |> html_response(422)

      assert html =~ "data-profile-shots"
      assert html =~ "data-career-shots"
      assert html =~ "data-landing-features"
    end

    test "the sign-up form still comes first", %{conn: conn} do
      html = landing(conn)

      form_at = :binary.match(html, "registration-form") |> elem(0)
      features_at = :binary.match(html, "data-landing-features") |> elem(0)

      assert form_at < features_at
    end
  end

  describe "German rendering" do
    test "the section headings are German", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "So sieht ein Profil auf vutuv aus"
      assert html =~ "Beiträge, Nachrichten und das Fediverse gleich dazu"
      # The word itself and a network people have heard of, both by name.
      assert html =~ "Fediverse"
      assert html =~ "Mastodon"
      # The part people need to read: it is a choice, made at sign-up and
      # reversible, not something that happens to them.
      # Not just "you choose" but the choice named as what it is, so somebody
      # who wants no Fediverse at all reads that it is on offer.
      assert html =~ "mit oder ohne Fediverse"
      assert html =~ "bei der Anmeldung"
      assert html =~ "in den Einstellungen ändern"
      assert html =~ "Was vutuv kann"
      assert html =~ "Selbst hosten"
    end

    # The two eyebrows of the sections added with the CV and Arbeitszeugnis
    # blocks. Both are single words, which is exactly the shape
    # `gettext.extract --merge` fuzzy-fills with something unrelated: "Job
    # applications" first came back as "Ihre Anwendungen", i.e. software.
    test "the new section labels are German", %{conn: conn} do
      html = landing_de(conn)

      assert html =~ "Bewerbungsunterlagen"
      assert html =~ "Arbeitszeugnis"
      refute html =~ "Ihre Anwendungen"
    end
  end
end
