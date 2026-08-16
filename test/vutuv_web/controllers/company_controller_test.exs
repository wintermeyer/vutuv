defmodule VutuvWeb.CompanyControllerTest do
  @moduledoc """
  The two company pages behind the footer's "Company" group, plus the footer
  itself: that its groups render, that both pages stay English under a German
  `Accept-Language` header, and that the investor page's figures are read from
  the database rather than typed into the template.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.PeopleHistory.Snapshot
  alias Vutuv.Repo
  alias VutuvWeb.AgentDocs.InvestorsDoc
  alias VutuvWeb.AgentDocs.MediaKitDoc
  alias VutuvWeb.CompanyHTML

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
      # translated. Matched as headings and not as bare words: "Netzwerk" is
      # also the top bar's nav label, so `html =~ "Netzwerk"` would pass on a
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

    test "carries the two new pages, labelled in English in the German footer", %{conn: conn} do
      html = conn |> german() |> get(~p"/") |> html_response(200)

      assert html =~ ~s|href="/system/investors"|
      assert html =~ ~s|href="/system/media-kit"|
      # The label stays English on purpose: it warns that the page is.
      assert html =~ ">Investors<"
      assert html =~ ">Media Kit<"
    end
  end

  describe "GET /system/investors" do
    test "opens with the way to start a conversation", %{conn: conn} do
      html = conn |> get(~p"/system/investors") |> html_response(200)

      # The contact card carries the page's only h1.
      assert html =~ "<h1"
      assert html =~ "Contact #{MediaKitDoc.press_contact_name()}"
      assert html =~ ~s|href="mailto:#{MediaKitDoc.press_contact()}"|
      assert length(Regex.scan(~r{<h1[^>]*>}, html)) == 1
    end

    test "points at the profile for the rest of the contact details", %{conn: conn} do
      handle = Application.get_env(:vutuv, :operator_handle)
      insert(:activated_user, username: handle)
      url = InvestorsDoc.contact_profile_url()

      html = conn |> get(~p"/system/investors") |> html_response(200)

      assert html =~ "More contact information on my profile"
      assert html =~ ~s|href="#{url}"|
      assert html =~ ">#{url}</a>"
    end

    test "points at no profile where that handle is nobody here", %{conn: conn} do
      refute InvestorsDoc.contact_profile_url()

      html = conn |> get(~p"/system/investors") |> html_response(200)

      refute html =~ "More contact information on my profile"
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

    test "stays English under a German Accept-Language header", %{conn: conn} do
      html = conn |> german() |> get(~p"/system/investors") |> html_response(200)

      assert html =~ ~s|lang="en"|
      assert html =~ "Where we are"
    end

    test "serves its agent-format siblings", %{conn: conn} do
      json = conn |> get(~p"/system/investors" <> ".json") |> json_response(200)

      assert json["type"] == "investors"
      assert json["contact"] == MediaKitDoc.press_contact()
      assert is_integer(json["figures"]["members"])
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

  describe "figures on an English-only page" do
    test "are grouped the English way whatever locale the request carries" do
      # Process-local, so this does not leak into a concurrent test.
      Gettext.put_locale(VutuvWeb.Gettext, "de")

      # The house formatter follows the request, which is right everywhere else
      # and wrong inside an English sentence: "5.934" reads as five point nine
      # three four to the reader this page is written for.
      assert VutuvWeb.UI.delimited_count(5934) == "5.934"
      assert CompanyHTML.en_count(5934) == "5,934"
    end
  end
end
