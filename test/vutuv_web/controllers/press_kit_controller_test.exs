defmodule VutuvWeb.PressKitControllerTest do
  @moduledoc """
  The public press surfaces (issue #2086): the Press card on the profile and the
  section page at `/:slug/media-kit` that hands the files out.

  What the tests below hold:

    * the card draws the photos as a mosaic with the `+N` past five tiles, the
      logo variants beside them and the one rights sentence, and links to the
      section page for **every** visitor — the page is where the download is,
      not merely a longer list;
    * the section page names each picture's caption, credit, dimensions and
      **formatted** file size, and offers a vector logo's SVG beside its PNG;
    * a picture the AI gate has not released is the owner's real photo and a
      stranger's stand-in, and a stranger is offered no download for it;
    * this is the one page under a member's slug that is **crawlable** — no
      `noindex`, a sitemap entry, and schema.org `ImageObject` markup carrying
      the four properties image search reads to call a picture licensable;
    * the German page says the German words, which is what a `.po` fuzzy-fill
      would otherwise ship as confident nonsense.

  Rows are inserted directly rather than uploaded: every one of these surfaces
  builds proxy URLs and reads columns, and none of them opens a file — the
  upload path itself is `press_kit_test.exs`'s.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.ImageHelpers, only: [put_press_picture: 1, put_press_picture: 2]

  alias Vutuv.PressKit
  alias Vutuv.Repo

  setup do
    user = insert_activated_user(username: "presse.person", first_name: "Ada", last_name: "King")
    {:ok, user: user}
  end

  defp de(conn), do: put_req_header(conn, "accept-language", "de-DE,de;q=0.9")

  # The `associatedMedia` of the page's schema.org block, decoded.
  defp json_ld_media(html), do: html |> json_ld("CollectionPage") |> Map.fetch!("associatedMedia")

  describe "the Press card on the profile" do
    test "shows the photos, the logos and the rights line", %{conn: conn, user: user} do
      put_press_picture(user, alt: "Am Schreibtisch", credit: "Foto: Rea Fotografin")

      put_press_picture(user,
        logo: true,
        position: 0,
        alt: "Wortmarke, dunkel",
        content_type: "image/svg+xml"
      )

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "profile-press"
      assert html =~ "data-press-photos"
      assert html =~ "data-press-logos"
      assert html =~ "Wortmarke, dunkel"
      assert html =~ "Free for editorial use with credit."
      # The credit rides on the tile so the lightbox can show it (#2086 folded
      # #2088 in, and the overlay reads everything off the page).
      assert html =~ "Foto: Rea Fotografin"
      assert html =~ "/presse.person/media-kit"
    end

    test "a sixth photo folds into a +N on the last tile", %{conn: conn, user: user} do
      for position <- 0..5, do: put_press_picture(user, position: position)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "data-press-more"
      assert html =~ "+1"
    end

    test "the card is not there for a member without one", %{conn: conn, user: user} do
      html = conn |> get(~p"/#{user}") |> html_response(200)

      refute html =~ "profile-press"
    end

    test "its owner gets the add tile instead of an empty card", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)

      html = conn |> get(~p"/#{owner}") |> html_response(200)

      assert html =~ "profile-press"
      assert html =~ "/settings/media-kit"
    end
  end

  describe "the section page" do
    test "names each picture's caption, credit, dimensions and file size",
         %{conn: conn, user: user} do
      put_press_picture(user,
        caption: "Auf der Bühne in Bremen",
        credit: "Foto: Rea Fotografin",
        size_bytes: 2_400_000
      )

      html = conn |> get(~p"/#{user}/media-kit") |> html_response(200)

      assert html =~ "Auf der Bühne in Bremen"
      assert html =~ "Foto: Rea Fotografin"
      # The dimensions are the row's; the **size** is measured off the file the
      # download hands over (issue #2140), which these inserted rows do not
      # have, so no figure is stated rather than the upload's length guessed at.
      # `VutuvWeb.PressKitMachineDataTest` uploads a real photo and pins the
      # formatted byte count against what the download route delivers.
      assert html =~ "3000 × 2000"
      refute html =~ "2400000"
      assert html =~ "data-press-download"
    end

    test "a vector logo offers its SVG and its PNG", %{conn: conn, user: user} do
      logo = put_press_picture(user, logo: true, content_type: "image/svg+xml", alt: "Wortmarke")

      html = conn |> get(~p"/#{user}/media-kit") |> html_response(200)

      assert html =~ "/system/press_kit/#{logo.token}/download.orig"
      assert html =~ "/system/press_kit/#{logo.token}/download.png"
      assert html =~ "Wortmarke"
    end

    test "a photo offers only the one file", %{conn: conn, user: user} do
      photo = put_press_picture(user)

      html = conn |> get(~p"/#{user}/media-kit") |> html_response(200)

      assert html =~ "/system/press_kit/#{photo.token}/download.orig"
      refute html =~ "/system/press_kit/#{photo.token}/download.png"
    end

    test "an empty press kit is an empty page rather than a 404", %{conn: conn, user: user} do
      assert conn |> get(~p"/#{user}/media-kit") |> html_response(200)
    end
  end

  describe "a picture the AI check has not released" do
    setup %{user: user} do
      {:ok, pending: put_press_picture(user, moderation: "pending", caption: "Wartet noch")}
    end

    test "a stranger gets no picture and no download", %{conn: conn, user: user, pending: pending} do
      html = conn |> get(~p"/#{user}/media-kit") |> html_response(200)

      # The tile is drawn — a hole in the page is worse — but nothing points at
      # the file, and the proxy would refuse it anyway.
      assert html =~ "data-press-held"
      refute html =~ "/system/press_kit/#{pending.token}/download.orig"
      refute html =~ "/system/press_kit/#{pending.token}/large.avif"
    end

    test "its owner sees the real picture and its download", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      pending = put_press_picture(owner, moderation: "pending")

      html = conn |> get(~p"/#{owner}/media-kit") |> html_response(200)

      assert html =~ "/system/press_kit/#{pending.token}/download.orig"
      refute html =~ "data-press-held"
    end

    test "it is in no agent document", %{conn: conn, user: user, pending: pending} do
      body = conn |> get("/#{user.username}/media-kit.json") |> Map.fetch!(:resp_body)

      assert %{"photos" => [], "logos" => []} = Jason.decode!(body)
      refute body =~ pending.token
    end
  end

  describe "the three bios (issue #2101)" do
    setup %{user: user} do
      {:ok, _bio} =
        PressKit.save_bio(user, user, %{
          "short" => "Ada King builds **bridges** in Bonn.",
          "long" => "Portraits by @reafotografin."
        })

      :ok
    end

    test "the page renders each written one and offers it for copying", %{conn: conn, user: user} do
      html = conn |> get(~p"/#{user}/media-kit") |> html_response(200)

      assert html =~ "data-press-bios"
      assert html =~ ~s(data-press-bio="short")
      assert html =~ ~s(data-press-bio="long")
      # A length nobody wrote is absent, not an empty block.
      refute html =~ ~s(data-press-bio="medium")

      # Rendered as Markdown, exactly as a post is…
      assert html =~ "<strong>bridges</strong>"
      # …and what the Copy button hands over is the prose, not the marks.
      assert html =~ ~s(data-copy-text="Ada King builds bridges in Bonn.")
    end

    test "an @handle in a bio links to that profile and notifies nobody", %{
      conn: conn,
      user: user
    } do
      photographer = insert_activated_user(username: "reafotografin")

      html = conn |> get(~p"/#{user}/media-kit") |> html_response(200)

      assert html =~ ~s(href="/reafotografin")
      assert Vutuv.Activity.notifications_count(photographer.id) == 0
    end

    test "a member with bios and no pictures still has a page", %{conn: conn, user: user} do
      html = conn |> get(~p"/#{user}/media-kit") |> html_response(200)

      assert html =~ "data-press-bios"
      # The rights sentence belongs to the pictures, and there are none.
      refute html =~ "offered for editorial use"
    end

    test "every agent format carries them", %{conn: conn, user: user} do
      md = conn |> get("/#{user.username}/media-kit.md") |> Map.fetch!(:resp_body)
      txt = conn |> get("/#{user.username}/media-kit.txt") |> Map.fetch!(:resp_body)
      json = conn |> get("/#{user.username}/media-kit.json") |> Map.fetch!(:resp_body)
      xml = conn |> get("/#{user.username}/media-kit.xml") |> Map.fetch!(:resp_body)

      for {format, body} <- %{md: md, txt: txt, json: json, xml: xml} do
        assert body =~ "Short version", "the label is missing from the #{format} version"
        assert body =~ "builds", "the short bio is missing from the #{format} version"
        assert body =~ "reafotografin", "the long bio is missing from the #{format} version"
      end

      # The stored Markdown reaches an agent as Markdown — a `.md` reader wants
      # the marks, and the label tells it which length it is holding.
      assert md =~ "### Short version"
      assert md =~ "**bridges**"

      assert %{"bios" => [short, long]} = Jason.decode!(json)
      assert short["length"] == "short"
      assert long["length"] == "long"
      assert short["text"] =~ "**bridges**"
    end

    test "the German page says the German words", %{conn: conn, user: user} do
      html = conn |> de() |> get(~p"/#{user}/media-kit") |> html_response(200)

      assert html =~ "Über Ada King"
      assert html =~ "Kurze Fassung"
      assert html =~ "Lange Fassung"
      assert html =~ "Kopieren"
    end
  end

  describe "the agent formats" do
    setup %{user: user} do
      put_press_picture(user,
        caption: "Auf der Buehne",
        credit: "Foto: Rea",
        alt: "Portraet",
        size_bytes: 2_400_000
      )

      put_press_picture(user, logo: true, content_type: "image/svg+xml", alt: "Wortmarke")
      :ok
    end

    test "every format carries the same facts", %{conn: conn, user: user} do
      rendered = %{
        html: conn |> get(~p"/#{user}/media-kit") |> html_response(200),
        md: conn |> get("/#{user.username}/media-kit.md") |> Map.fetch!(:resp_body),
        txt: conn |> get("/#{user.username}/media-kit.txt") |> Map.fetch!(:resp_body),
        json: conn |> get("/#{user.username}/media-kit.json") |> Map.fetch!(:resp_body),
        xml: conn |> get("/#{user.username}/media-kit.xml") |> Map.fetch!(:resp_body)
      }

      for fact <- ["Portraet", "Wortmarke", "Foto: Rea", "download.orig"],
          {format, body} <- rendered do
        assert body =~ fact, "#{fact} is missing from the #{format} version"
      end

      doc = Jason.decode!(rendered.json)
      assert doc["type"] == "press_kit"
      assert doc["total"] == 2
      assert length(doc["photos"]) == 1
      assert length(doc["logos"]) == 1
      assert [%{"png_download_url" => png}] = doc["logos"]
      assert png =~ "download.png"
      assert doc["owner"]["username"] == "presse.person"
      assert doc["rights"] =~ "editorial"
    end

    test "a .md URL never serves HTML", %{conn: conn, user: user} do
      conn = get(conn, ~p"/#{user}/media-kit.md")

      assert get_resp_header(conn, "content-type") == ["text/markdown; charset=utf-8"]
      refute conn.resp_body =~ "<!DOCTYPE"
    end

    test "the profile document lists the kit too", %{conn: conn, user: user} do
      doc = conn |> get("/#{user.username}.json") |> Map.fetch!(:resp_body) |> Jason.decode!()

      assert length(doc["press_kit"]) == 2
      assert Enum.any?(doc["press_kit"], &(&1["label"] == "Wortmarke"))
    end
  end

  describe "it is the one crawlable page under a member's slug" do
    test "no noindex header, unlike every other section page", %{conn: conn, user: user} do
      put_press_picture(user)

      press = get(conn, ~p"/#{user}/media-kit")
      links = get(conn, ~p"/#{user}/links")

      assert get_resp_header(press, "x-robots-tag") == []
      assert get_resp_header(links, "x-robots-tag") == ["noindex, noai, noimageai"]
    end

    test "a member who opted out of search still gets theirs", %{conn: conn, user: user} do
      Repo.update!(Ecto.Changeset.change(user, noindex?: true))
      put_press_picture(user)

      conn = get(conn, ~p"/#{user}/media-kit")

      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
      # …and their page describes itself to nobody.
      refute html_response(conn, 200) =~ "application/ld+json\">\n{\n  \"@context"
    end

    test "the pictures carry the licensable schema.org markup", %{conn: conn, user: user} do
      put_press_picture(user, credit: "Foto: Rea Fotografin", caption: "Auf der Buehne")

      html = conn |> get(~p"/#{user}/media-kit") |> html_response(200)

      assert html =~ ~s("@type": "CollectionPage")
      assert html =~ ~s("@type": "ImageObject")
      assert html =~ ~s("creditText": "Foto: Rea Fotografin")
      assert html =~ ~s("copyrightNotice": "Foto: Rea Fotografin")
      assert html =~ "acquireLicensePage"
      assert html =~ "/presse.person/media-kit"
    end

    test "the markup names the same pictures whoever is looking", %{conn: conn} do
      {owner_conn, owner} = create_and_login_user(conn)
      put_press_picture(owner, position: 0)
      pending = put_press_picture(owner, position: 1, moderation: "pending")

      # The owner's own page shows them the picture the AI gate still holds, so
      # `views/2` calls it visible — but the markup speaks to a crawler, which is
      # always anonymous and would fetch a 404.
      html = owner_conn |> get(~p"/#{owner}/media-kit") |> html_response(200)

      # Read the block rather than grepping the page: `JsonLd.script/1` encodes
      # with `escape: :html_safe`, so every `/` in it is `\/` and a `refute` on
      # a bare URL passes without ever matching anything.
      assert [media] = json_ld_media(html)
      refute media["contentUrl"] =~ pending.token
    end

    test "a member with pictures is in the sitemap, one without is not", %{conn: conn, user: user} do
      quiet = insert_activated_user(username: "keine.presse")
      put_press_picture(user)

      index = conn |> get(~p"/sitemap.xml") |> Map.fetch!(:resp_body)
      assert index =~ "/sitemaps/press-1.xml"

      chunk = conn |> get(~p"/sitemaps/press-1.xml") |> Map.fetch!(:resp_body)
      assert chunk =~ "/presse.person/media-kit"
      refute chunk =~ "/#{quiet.username}/media-kit"
    end

    test "it is listed in /llms.txt", %{conn: conn} do
      assert conn |> get(~p"/llms.txt") |> Map.fetch!(:resp_body) =~ "/<username>/media-kit"
    end
  end

  describe "in German" do
    test "the card and the page say the German words", %{conn: conn, user: user} do
      put_press_picture(user, caption: "Auf der Buehne", credit: "Foto: Rea")
      put_press_picture(user, logo: true, alt: "Wortmarke", content_type: "image/svg+xml")

      card = conn |> de() |> get(~p"/#{user}") |> html_response(200)
      page = conn |> de() |> get(~p"/#{user}/media-kit") |> html_response(200)

      assert card =~ "Media Kit"
      assert card =~ "Zur freien redaktionellen Verwendung mit Bildnachweis."
      assert page =~ "Pressefotos"
      assert page =~ "Logo-Varianten"
      assert page =~ "Foto herunterladen"
      assert page =~ "SVG herunterladen"
      # The section-page heading names the member, not a bare category.
      assert page =~ "Media Kit von Ada King"
    end
  end
end
