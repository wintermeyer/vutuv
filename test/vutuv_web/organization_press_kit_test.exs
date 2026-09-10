defmodule VutuvWeb.OrganizationPressKitTest do
  @moduledoc """
  A page's press section (issue #2087): the card on the organization page and
  the section page at `/organizations/:slug/media-kit` that hands the files over —
  the twin of the member surfaces #2086 built, drawn by the same components off
  the same two shelves.

  What the tests below hold:

    * the same card and the same section page, for a page rather than a member,
      with every URL built from the page's slug — a page that claimed a root
      handle is **not** addressed by it here, because the handle dispatches only
      the bare `/:slug`;
    * the rows are the **page's**: a picture stays when the colleague who
      uploaded it closes their account, and every owner and publisher sees the
      one the AI check is still holding — not only whoever uploaded it;
    * the agent-format siblings, the sitemap entry and the schema.org markup a
      member's press page carries, which is the whole reason that page is
      crawlable at all;
    * the German page says the German words, which is what a `.po` fuzzy-fill
      would otherwise ship as confident nonsense.

  Rows are inserted rather than uploaded: every surface here builds proxy URLs
  and reads columns, and none of them opens a file. The upload path itself is
  `VutuvWeb.PressKitLiveTest`'s.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.ImageHelpers, only: [put_press_picture: 1, put_press_picture: 2]

  alias Vutuv.Accounts
  alias Vutuv.Organizations
  alias Vutuv.Repo

  setup do
    organization = insert(:organization, name: "Acme GmbH")
    {:ok, organization: organization}
  end

  defp de(conn), do: put_req_header(conn, "accept-language", "de-DE,de;q=0.9")

  defp press_path(organization), do: "/organizations/#{organization.slug}/media-kit"

  # A team member holding `role` on the page, and a conn signed in as them.
  defp team_member(conn, organization, role) do
    {conn, member} = create_and_login_user(conn)
    {:ok, _} = Organizations.add_role(organization, member, role, member)
    {conn, member}
  end

  describe "the card on the organization page" do
    test "shows the photos, the logos and the rights line", %{
      conn: conn,
      organization: organization
    } do
      put_press_picture(organization, alt: "Vor dem Werk", credit: "Foto: Rea Fotografin")
      put_press_picture(organization, logo: true, alt: "Wortmarke, dunkel")

      html = conn |> get(~p"/organizations/#{organization.slug}") |> html_response(200)

      assert html =~ "organization-press"
      assert html =~ "data-press-photos"
      assert html =~ "data-press-logos"
      assert html =~ "data-press-rights"
      assert html =~ "Wortmarke, dunkel"
      assert html =~ press_path(organization)
    end

    test "is not there for a page without one", %{conn: conn, organization: organization} do
      html = conn |> get(~p"/organizations/#{organization.slug}") |> html_response(200)

      refute html =~ "organization-press"
    end

    test "its team gets the add tile instead of an empty card", %{
      conn: conn,
      organization: organization
    } do
      {conn, _owner} = team_member(conn, organization, "owner")

      html = conn |> get(~p"/organizations/#{organization.slug}") |> html_response(200)

      assert html =~ "organization-press"
      assert html =~ "data-empty-add"
      assert html =~ "/organizations/#{organization.slug}/media-kit/edit"
    end
  end

  describe "the section page" do
    test "names each picture's caption, credit, dimensions and file size", %{
      conn: conn,
      organization: organization
    } do
      picture =
        put_press_picture(organization,
          caption: "Vor dem Werk in Bremen",
          credit: "Foto: Rea Fotografin",
          size_bytes: 2_400_000
        )

      html = conn |> get(press_path(organization)) |> html_response(200)

      assert html =~ "Media Kit of Acme GmbH"
      assert html =~ "Vor dem Werk in Bremen"
      assert html =~ "Foto: Rea Fotografin"
      assert html =~ "3000 × 2000 · 2.4 MB"
      assert html =~ "/system/press_kit/#{picture.token}/download.orig"
    end

    test "a vector logo offers its SVG and its PNG", %{conn: conn, organization: organization} do
      logo =
        put_press_picture(organization,
          logo: true,
          content_type: "image/svg+xml",
          alt: "Wortmarke"
        )

      html = conn |> get(press_path(organization)) |> html_response(200)

      assert html =~ "/system/press_kit/#{logo.token}/download.orig"
      assert html =~ "/system/press_kit/#{logo.token}/download.png"
    end

    test "an empty press kit is an empty page rather than a 404", %{
      conn: conn,
      organization: organization
    } do
      assert conn |> get(press_path(organization)) |> html_response(200)
    end

    test "a page nobody may see has no press page either", %{conn: conn} do
      hidden = insert(:organization, status: "pending")

      assert conn |> get(press_path(hidden)) |> html_response(404)
    end

    test "its team reaches the editor from the page, a stranger sees no such link", %{
      conn: conn,
      organization: organization
    } do
      put_press_picture(organization)
      {owner_conn, _owner} = team_member(conn, organization, "owner")

      assert owner_conn |> get(press_path(organization)) |> html_response(200) =~
               "/organizations/#{organization.slug}/media-kit/edit"

      refute conn |> get(press_path(organization)) |> html_response(200) =~ "press/edit"
    end
  end

  describe "the rows belong to the page, not to whoever uploaded them" do
    test "a picture stays when the colleague who uploaded it closes their account", %{
      organization: organization
    } do
      colleague = insert(:activated_user)

      picture =
        put_press_picture(organization, uploader_user_id: colleague.id, alt: "Vor dem Werk")

      assert {:ok, _} = Accounts.delete_user(colleague)

      kept = Repo.get(Vutuv.Images.Image, picture.id)

      assert kept
      assert kept.organization_id == organization.id
      assert is_nil(kept.uploader_user_id)
    end

    test "a picture the AI check holds is shown to every owner and publisher", %{
      conn: conn,
      organization: organization
    } do
      uploader = insert(:activated_user)
      {:ok, _} = Organizations.add_role(organization, uploader, "publisher", uploader)

      pending =
        put_press_picture(organization,
          moderation: "pending",
          uploader_user_id: uploader.id
        )

      # Somebody else on the team — the colleague who has to be able to look at
      # what is being checked, which is the whole point of #2087's gate.
      {owner_conn, _owner} = team_member(conn, organization, "owner")
      {publisher_conn, _publisher} = team_member(conn, organization, "publisher")

      for team_conn <- [owner_conn, publisher_conn] do
        html = team_conn |> get(press_path(organization)) |> html_response(200)

        assert html =~ "/system/press_kit/#{pending.token}/download.orig"
        refute html =~ "data-press-held"
      end

      stranger = conn |> get(press_path(organization)) |> html_response(200)

      assert stranger =~ "data-press-held"
      refute stranger =~ "/system/press_kit/#{pending.token}/download.orig"
    end
  end

  describe "the agent formats" do
    setup %{organization: organization} do
      put_press_picture(organization,
        alt: "Vor dem Werk",
        credit: "Foto: Rea Fotografin",
        caption: "Die Halle in Bremen"
      )

      :ok
    end

    test "every format carries the same facts", %{conn: conn, organization: organization} do
      for extension <- ~w(.md .txt .json .xml) do
        body = conn |> get(press_path(organization) <> extension) |> Map.fetch!(:resp_body)

        assert body =~ "Acme GmbH", "#{extension} does not name the page"
        assert body =~ "Foto: Rea Fotografin", "#{extension} does not carry the credit"
        assert body =~ "download.orig", "#{extension} offers no download"
      end
    end

    test "the JSON names the page as the owner and the page's own URL", %{
      conn: conn,
      organization: organization
    } do
      doc =
        conn
        |> get(press_path(organization) <> ".json")
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()

      assert doc["owner"]["name"] == "Acme GmbH"
      assert doc["url"] =~ press_path(organization)
      assert [%{"credit" => "Foto: Rea Fotografin"}] = doc["photos"]
    end

    test "a .md URL never serves HTML", %{conn: conn, organization: organization} do
      body = conn |> get(press_path(organization) <> ".md") |> Map.fetch!(:resp_body)

      refute body =~ "<html"
    end

    test "a page that serves no agent documents serves none of these either", %{conn: conn} do
      quiet = insert(:organization, geo?: false)
      put_press_picture(quiet)

      assert conn |> get(press_path(quiet) <> ".json") |> Map.fetch!(:status) == 404
    end
  end

  describe "it is crawlable, like a member's" do
    test "no noindex header, and the pictures carry the licensable markup", %{
      conn: conn,
      organization: organization
    } do
      put_press_picture(organization, credit: "Foto: Rea Fotografin")

      conn = get(conn, press_path(organization))
      html = html_response(conn, 200)

      assert get_resp_header(conn, "x-robots-tag") == []
      assert html =~ ~s("@type": "CollectionPage")
      assert html =~ ~s("@type": "ImageObject")
      assert html =~ ~s("creditText": "Foto: Rea Fotografin")
      assert html =~ "acquireLicensePage"
    end

    test "a page that opted out of search engines is noindexed", %{
      conn: conn,
      organization: organization
    } do
      Repo.update!(Ecto.Changeset.change(organization, seo?: false))
      put_press_picture(organization)

      conn = get(conn, press_path(organization))

      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
    end

    test "a page with pictures is in the sitemap, one without is not", %{
      conn: conn,
      organization: organization
    } do
      quiet = insert(:organization)
      put_press_picture(organization)

      index = conn |> get(~p"/sitemap.xml") |> Map.fetch!(:resp_body)
      assert index =~ "/sitemaps/organization_press-1.xml"

      chunk = conn |> get("/sitemaps/organization_press-1.xml") |> Map.fetch!(:resp_body)
      assert chunk =~ press_path(organization)
      refute chunk =~ press_path(quiet)
    end

    test "it is listed in /llms.txt", %{conn: conn} do
      assert conn |> get(~p"/llms.txt") |> Map.fetch!(:resp_body) =~
               "/organizations/<slug>/media-kit"
    end
  end

  describe "in German" do
    test "the card and the page say the German words", %{
      conn: conn,
      organization: organization
    } do
      put_press_picture(organization, caption: "Die Halle", credit: "Foto: Rea")
      put_press_picture(organization, logo: true, alt: "Wortmarke", content_type: "image/svg+xml")

      card = conn |> de() |> get(~p"/organizations/#{organization.slug}") |> html_response(200)
      page = conn |> de() |> get(press_path(organization)) |> html_response(200)

      assert card =~ "Media Kit"
      assert card =~ "Zur freien redaktionellen Verwendung mit Bildnachweis."
      assert page =~ "Pressefotos"
      assert page =~ "Logo-Varianten"
      assert page =~ "Foto herunterladen"
      assert page =~ "SVG herunterladen"
      # The heading names the page, not a bare category.
      assert page =~ "Media Kit von Acme GmbH"
    end
  end
end
