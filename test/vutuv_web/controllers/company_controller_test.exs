defmodule VutuvWeb.CompanyControllerTest do
  @moduledoc """
  The two company pages behind the footer's "Company" group, plus the footer
  itself: that its groups render, that the **media kit** stays English under a
  German `Accept-Language` header while the **investor page** follows the
  reader's language, that the investor page states no email address, and that
  its figures are read from the database rather than typed into the template.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.BerlinTime
  alias Vutuv.Fediverse
  alias Vutuv.PeopleHistory
  alias Vutuv.PeopleHistory.Snapshot
  alias Vutuv.Repo
  alias VutuvWeb.AgentDocs.InvestorsDoc
  alias VutuvWeb.AgentDocs.MediaKitDoc

  # The creating migration backfills 30 days, so the table is never empty even
  # in a fresh test database. Each test states its own history.
  setup do
    Repo.delete_all(Snapshot)
    :ok
  end

  defp german(conn), do: put_req_header(conn, "accept-language", "de-DE,de;q=0.9")

  describe "the footer" do
    test "groups its links under headings instead of one middot row", %{conn: conn} do
      html = conn |> german() |> get(~p"/") |> html_response(200)

      # The four group headings, in German, since the footer itself is
      # translated. Matched as headings and not as bare words: every one of
      # them is a common enough word that `html =~ "Netzwerk"` would pass on a
      # page with no footer groups at all.
      for heading <- ["Netzwerk", "Entwickler", "Unternehmen", "Rechtliches"] do
        assert html =~ ">#{heading}</h2>"
      end

      # Every link the old flat row carried is still reachable.
      for path <- [
            ~p"/system/members",
            ~p"/organizations",
            ~p"/jobs",
            ~p"/developers",
            ~p"/community",
            ~p"/datenschutzerklaerung",
            ~p"/nutzungsbedingungen",
            ~p"/impressum"
          ] do
        assert html =~ ~s|href="#{path}"|
      end
    end

    test "carries the two company pages, the media kit still labelled in English", %{conn: conn} do
      html = conn |> german() |> get(~p"/") |> html_response(200)

      assert html =~ ~s|href="/system/investors"|
      assert html =~ ~s|href="/system/media-kit"|
      # The media kit's label stays English: it warns that the page is.
      assert html =~ ">Media Kit<"
      # The investor page is translated now, so warning about a language change
      # that no longer happens would be the wrong signal.
      assert html =~ "Investoren"
      refute html =~ ">Investors<"
    end
  end

  describe "GET /system/investors" do
    test "opens on the claim, not on a contact card", %{conn: conn} do
      html = conn |> get(~p"/system/investors") |> html_response(200)

      assert html =~ "<h1"
      assert html =~ "A professional network that works without an account"
      assert length(Regex.scan(~r{<h1[^>]*>}, html)) == 1
    end

    test "states no email address, but does link the profile", %{conn: conn} do
      # The address stays off a page read by strangers and machines; the media
      # kit still carries it, for a journalist on a deadline. The profile is a
      # different matter: somebody about to put six figures somewhere wants to
      # see who is on the other side.
      insert(:activated_user, username: Application.get_env(:vutuv, :operator_handle))

      html = conn |> get(~p"/system/investors") |> html_response(200)

      refute html =~ MediaKitDoc.press_contact()
      refute html =~ "mailto:"
      assert html =~ ~s|href="#{InvestorsDoc.contact_profile_url()}"|
    end

    test "offers a message on this installation instead", %{conn: conn} do
      handle = Application.get_env(:vutuv, :operator_handle)
      insert(:activated_user, username: handle)

      html = conn |> get(~p"/system/investors") |> html_response(200)

      assert html =~ ~s|href="/messages/with/#{handle}"|
      # And the way in for somebody who has no account yet.
      assert html =~ "Create an account"
    end

    test "offers no contact at all where that handle is nobody here", %{conn: conn} do
      # A third-party installation running the shipped default: it must render
      # silence rather than point a reader at somebody on vutuv.de.
      refute InvestorsDoc.contact_handle()

      html = conn |> get(~p"/system/investors") |> html_response(200)

      refute html =~ "/messages/with/"
      refute html =~ "Write to me"

      # And the agent formats keep the same silence. They used to print the
      # invitation ("Write to me here, on vutuv…") with no heading above it and
      # no address under it, because only the heading and the link were gated.
      for extension <- [".md", ".txt"] do
        body = conn |> get(~p"/system/investors" <> extension) |> response(200)

        refute body =~ "Write to me"
        refute body =~ "/messages/with/"
        refute body =~ "My profile"
      end
    end

    test "shows the arithmetic behind the number in the top bar", %{conn: conn} do
      # Investors have asked how that figure comes about, which is why the
      # addition is spelled out rather than described.
      insert(:activated_user)
      insert(:activated_user)
      insert(:activated_user)

      html = conn |> get(~p"/system/investors") |> html_response(200)

      assert html =~ "3 members + 0 Fediverse accounts = 3 people"
      assert html =~ "That total is the number in the top bar"
      assert html =~ "Nobody is counted twice"
    end

    test "the two tiles it adds are the ones the top bar counts", %{conn: conn} do
      # The equation is only honest if its summands are the very figures
      # `Vutuv.PeopleCounter` adds up for the bar, so this pins the sources
      # rather than the arithmetic. Asserted against those functions and not
      # against `PeopleCounter.counts/0`: that reads a process-wide atomics
      # cell the SQL sandbox never sees, so it answers 0 in a test and would
      # make an async module depend on shared state.
      insert(:activated_user)
      insert(:activated_user)

      facts = InvestorsDoc.facts()

      assert facts.members == Accounts.count_users()
      assert facts.fediverse_accounts == Fediverse.distinct_follower_count()

      html = conn |> get(~p"/system/investors") |> html_response(200)
      assert html =~ "= #{facts.members + facts.fediverse_accounts} people"
    end

    test "makes the case against LinkedIn's sign-up wall", %{conn: conn} do
      html = conn |> get(~p"/system/investors") |> html_response(200)

      for title <- [
            "Readable without an account",
            "Fast pages win",
            "The market behind the slow connection",
            "Advertising instead of a paywall"
          ] do
        assert html =~ title
      end
    end

    test "cites the measurements the speed and market claims lean on", %{conn: conn} do
      # An investor checks a figure like this, and one they cannot check reads
      # as one we made up. Asserted as links, not as prose: a named study with
      # no way to reach it is the same dead end.
      html = conn |> get(~p"/system/investors") |> html_response(200)

      assert html =~ ~s|href="https://web.dev/case-studies/milliseconds-make-millions"|
      assert html =~ "Milliseconds Make Millions"
      assert html =~ "PR-2025-11-17-Facts-and-Figures.aspx"
      assert html =~ "ITU, Facts and Figures 2025"
    end

    test "states the live figures", %{conn: conn} do
      insert(:activated_user)
      insert(:activated_user)

      html = conn |> get(~p"/system/investors") |> html_response(200)

      assert html =~ "Where we are"
      assert html =~ "Members"
      # The figure tile really carries the count from the database.
      assert html =~ ">2</p>"
    end

    test "draws the growth curve from the daily snapshots", %{conn: conn} do
      # The Berlin calendar day, which is what the recorder stamps.
      today = BerlinTime.today()
      PeopleHistory.record(Date.add(today, -2), %{members: 10, fediverse_accounts: 2})
      PeopleHistory.record(Date.add(today, -1), %{members: 14, fediverse_accounts: 3})
      PeopleHistory.record(today, %{members: 20, fediverse_accounts: 5})

      html = conn |> get(~p"/system/investors") |> html_response(200)

      assert html =~ "<polygon"
      # 25 people on the last day against 12 on the first.
      assert html =~ "13 people arrived"

      # The reading of the curve is a sentence about the network, not about the
      # drawing, so every format states it: an agent summarising this page
      # otherwise hands somebody the standing counts and nothing about the
      # movement, which is the half an investor came for.
      markdown = conn |> get(~p"/system/investors" <> ".md") |> response(200)
      assert markdown =~ "13 people arrived"
    end

    test "draws no curve for a series too short to be one", %{conn: conn} do
      PeopleHistory.record(BerlinTime.today(), %{members: 10, fediverse_accounts: 2})

      html = conn |> get(~p"/system/investors") |> html_response(200)

      # An empty chart frame says less than no chart at all.
      refute html =~ "<polygon"
    end

    test "renders in German on a German Accept-Language header", %{conn: conn} do
      html = conn |> german() |> get(~p"/system/investors") |> html_response(200)

      # Asserted by name because `gettext.extract --merge` fuzzy-fills a new
      # msgid with the translation of whatever it looks similar to and fails no
      # build, so a German page can ship confident nonsense while every English
      # assertion here stays green.
      assert html =~ "Ein Berufsnetzwerk, das ohne Konto funktioniert"
      # The whole sentence, not just its opening: a stale compiled catalogue
      # answers a changed msgid with its previous translation, and a prefix
      # match passes straight through that. `mix compile` does not always
      # notice a rewritten `.po` — this shipped the dropped half-sentence for
      # one round, green tests and all.
      assert html =~
               "Diese Seite richtet sich an potentielle Investoren. Sie sagt, was vutuv ist, " <>
                 "wo das Netzwerk heute steht und womit es eines Tages Geld verdienen soll."

      assert html =~ "Ohne Konto lesbar"
      assert html =~ "Schnelle Seiten gewinnen"
      assert html =~ "Der Markt hinter der langsamen Leitung"
      assert html =~ "Quelle:"
      assert html =~ "Anzeigen statt Bezahlschranke"
      assert html =~ "Wo wir stehen"
      assert html =~ "Mitglieder + "
      assert html =~ " = "
      assert html =~ "Diese Summe steht oben in der Navigationsleiste"
      assert html =~ "Mitglieder"

      # The English page must not show through anywhere.
      refute html =~ "Where we are"
      refute html =~ "Readable without an account"
    end

    test "serves its agent-format siblings", %{conn: conn} do
      json = conn |> get(~p"/system/investors" <> ".json") |> json_response(200)

      assert json["type"] == "investors"
      assert is_integer(json["figures"]["members"])
      assert json["language"] == "en"
      # No address here either: an agent summarising this page for somebody
      # must not be the way the address gets out.
      refute json["contact"]
      refute Jason.encode!(json) =~ MediaKitDoc.press_contact()
    end

    test "the Markdown sibling carries the argument, not only the counts", %{conn: conn} do
      markdown = conn |> get(~p"/system/investors" <> ".md") |> response(200)

      assert markdown =~ "# A professional network that works without an account"
      assert markdown =~ "### Readable without an account"
    end

    test "the agent formats are translatable too, on ?lang=", %{conn: conn} do
      # An agent document's content is deliberately locale-stable (English
      # unless `?lang=` says otherwise, see `VutuvWeb.AgentDocs`), so a German
      # `Accept-Language` header gets the English document plus a pointer to
      # this URL. What matters here is that the pointer leads somewhere real.
      hint = conn |> german() |> get(~p"/system/investors" <> ".md") |> response(200)
      assert hint =~ "Diese Seite auf Deutsch"

      markdown = conn |> get(~p"/system/investors" <> ".md?lang=de") |> response(200)

      assert markdown =~ "Ein Berufsnetzwerk, das ohne Konto funktioniert"
      assert markdown =~ "Warum sich das lohnt"
    end
  end

  describe "GET /system/media-kit" do
    test "hands out the boilerplate, the assets and the contact", %{conn: conn} do
      html = conn |> get(~p"/system/media-kit") |> html_response(200)

      assert html =~ "Media Kit"
      assert html =~ MediaKitDoc.boilerplate().short
      assert html =~ "/images/brand/vutuv-wordmark.svg"
      assert html =~ MediaKitDoc.press_contact()
    end

    test "stays English under a German Accept-Language header", %{conn: conn} do
      html = conn |> german() |> get(~p"/system/media-kit") |> html_response(200)

      assert html =~ ~s|lang="en"|
      assert html =~ "Brand assets"
    end

    test "names the person, not just the address, and links their profile", %{conn: conn} do
      # The literal handle is the point of the test: it has to be the one the
      # installation is configured with, or the lookup would not resolve. No
      # other async file inserts this exact username.
      handle = Application.get_env(:vutuv, :operator_handle)
      insert(:activated_user, username: handle)

      html = conn |> get(~p"/system/media-kit") |> html_response(200)

      url = MediaKitDoc.press_contact_profile_url()

      assert html =~ MediaKitDoc.press_contact_name()
      assert html =~ MediaKitDoc.press_contact()
      # The address is the link text, not a label over it: a reader has to see
      # what a vutuv profile URL looks like.
      assert html =~ ~s|href="#{url}"|
      assert html =~ ">#{url}</a>"
    end

    test "links no profile where that handle is nobody here", %{conn: conn} do
      # No such member, which is a third-party installation running the shipped
      # default: it must render silence, never a link to somebody on vutuv.de.
      refute MediaKitDoc.press_contact_profile_url()

      html = conn |> get(~p"/system/media-kit") |> html_response(200)

      assert html =~ MediaKitDoc.press_contact_name()
      # Anchored on the profile paragraph's own wording, not on a phrase that
      # never appears on the page either way.
      refute html =~ "Phone, messengers and everything else"
    end

    test "every asset and screenshot it offers is really served", %{conn: conn} do
      for %{path: path} <- MediaKitDoc.assets() ++ MediaKitDoc.screenshots() do
        assert File.exists?(Path.join("priv/static", path)),
               "#{path} is offered on the media kit but not in priv/static"

        # And it really is reachable, not merely present on disk.
        assert conn |> get(path) |> response(200)
      end
    end

    test "the page and its Markdown sibling carry the same boilerplate", %{conn: conn} do
      markdown = conn |> get(~p"/system/media-kit" <> ".md") |> response(200)

      assert markdown =~ MediaKitDoc.boilerplate().short
      assert markdown =~ MediaKitDoc.press_contact()
    end
  end
end
