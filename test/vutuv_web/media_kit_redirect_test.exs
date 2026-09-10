defmodule VutuvWeb.MediaKitRedirectTest do
  @moduledoc """
  The area a member and a journalist meet is the **Media Kit** (issue #2100),
  and it moved: `/:slug/press` is `/:slug/media-kit`, `/settings/press` is
  `/settings/media-kit`, and a page's is `/organizations/:slug/media-kit`.

  What the tests below hold:

    * every old address answers a **permanent** redirect rather than a 404 —
      `/:slug/press` sat in the sitemap and in `/llms.txt`, so it leaves its
      address behind;
    * so does each of its four agent-format siblings, and each lands on the
      **same** format's new address: a `.md` URL must never redirect to HTML
      (`VutuvWeb.Plug.AgentFormat` puts the extension back on a redirect's
      location, and this is what proves it does here);
    * the new addresses are the ones the app itself hands out — the profile
      card, the sitemap, `/llms.txt` and the settings hub all name them;
    * the German page says the German words, because a rename touches every
      string at once and a `.po` fuzzy-fill would ship confident nonsense.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Vutuv.ImageHelpers, only: [put_press_picture: 1, put_press_picture: 2]

  alias Vutuv.Organizations

  setup do
    user = insert_activated_user(username: "presse.person", first_name: "Ada", last_name: "King")
    organization = insert(:organization, name: "Acme GmbH")
    {:ok, user: user, organization: organization}
  end

  defp de(conn), do: put_req_header(conn, "accept-language", "de-DE,de;q=0.9")

  # The four agent formats plus the plain browser request, as the suffix each
  # one appends to a path.
  @suffixes ["", ".md", ".txt", ".json", ".xml"]

  describe "the member's old address" do
    test "301s to the media kit, in every format", %{conn: conn, user: user} do
      for suffix <- @suffixes do
        moved = get(conn, "/#{user.username}/press#{suffix}")

        assert moved.status == 301, "/#{user.username}/press#{suffix} did not redirect"

        assert redirected_to(moved, 301) == "/#{user.username}/media-kit#{suffix}",
               "/#{user.username}/press#{suffix} landed on the wrong address"
      end
    end

    test "a query string survives the move", %{conn: conn, user: user} do
      moved = get(conn, "/#{user.username}/press?utm_source=mail")

      assert redirected_to(moved, 301) == "/#{user.username}/media-kit?utm_source=mail"
    end

    test "it never answers for a route that owns its own second segment" do
      # `/:slug/press` is a two-segment pattern, so wherever it is defined it
      # shadows every `/<literal>/:param` route below it. It therefore sits at
      # the foot of the router, beside the page it retired. Defined up in the
      # retired-URLs scope it matched `/jobs/press` too — and a job posting's
      # slug is built from its title (`Vutuv.Jobs.put_slug/1`), so a posting
      # called "Press" would 301 to `/jobs/media-kit` and stay unreachable for
      # as long as the browser held the permanent redirect.
      for path <- [["jobs", "press"], ["messages", "press"], ["tags", "press"]] do
        %{plug: plug} = Phoenix.Router.route_info(VutuvWeb.Router, "GET", path, "localhost")

        refute plug == VutuvWeb.LegacyRedirectController,
               "/#{Enum.join(path, "/")} is answered by the retired press route"
      end

      assert %{plug: VutuvWeb.LegacyRedirectController} =
               Phoenix.Router.route_info(
                 VutuvWeb.Router,
                 "GET",
                 ["ada.king", "press"],
                 "localhost"
               )
    end

    test "the new address serves the page and its siblings", %{conn: conn, user: user} do
      put_press_picture(user, alt: "Portraet", credit: "Foto: Rea Fotografin")

      assert conn |> get(~p"/#{user}/media-kit") |> html_response(200) =~ "Portraet"

      md = get(conn, "/#{user.username}/media-kit.md")

      assert get_resp_header(md, "content-type") == ["text/markdown; charset=utf-8"]
      refute md.resp_body =~ "<!DOCTYPE"
      assert md.resp_body =~ "Foto: Rea Fotografin"
    end

    test "the profile card and the sitemap name the new address", %{conn: conn, user: user} do
      put_press_picture(user)

      assert conn |> get(~p"/#{user}") |> html_response(200) =~ "/presse.person/media-kit"

      assert Enum.any?(Vutuv.Sitemap.press_entries(1), fn {path, _date} ->
               path == "/presse.person/media-kit"
             end)
    end
  end

  describe "the page's old addresses" do
    test "301 to the media kit, in every format", %{conn: conn, organization: organization} do
      for suffix <- @suffixes do
        moved = get(conn, "/organizations/#{organization.slug}/press#{suffix}")

        assert moved.status == 301, "the page's /press#{suffix} did not redirect"

        assert redirected_to(moved, 301) ==
                 "/organizations/#{organization.slug}/media-kit#{suffix}"
      end
    end

    test "the editor's old address 301s too", %{conn: conn, organization: organization} do
      moved = get(conn, "/organizations/#{organization.slug}/press/edit")

      assert redirected_to(moved, 301) == "/organizations/#{organization.slug}/media-kit/edit"
    end

    test "the new address serves the page", %{conn: conn, organization: organization} do
      put_press_picture(organization, alt: "Wortmarke", logo: true)

      html =
        conn
        |> get("/organizations/#{organization.slug}/media-kit")
        |> html_response(200)

      assert html =~ "Wortmarke"
    end

    test "an owner reaches the editor at the new address", %{
      conn: conn,
      organization: organization
    } do
      {conn, member} = create_and_login_user(conn)
      {:ok, _} = Organizations.add_role(organization, member, "owner", member)

      assert conn
             |> get("/organizations/#{organization.slug}/media-kit/edit")
             |> html_response(200) =~ "Media Kit"
    end
  end

  describe "the member's own editor" do
    setup %{conn: conn} do
      {conn, member} = create_and_login_user(conn)
      {:ok, conn: conn, member: member}
    end

    test "the old settings address 301s", %{conn: conn} do
      assert conn |> get("/settings/press") |> redirected_to(301) == "/settings/media-kit"
    end

    test "the settings hub links to the new address", %{conn: conn} do
      assert conn |> get(~p"/settings") |> html_response(200) =~ ~s(href="/settings/media-kit")
    end
  end

  describe "the German words" do
    test "the section page is German, not a fuzzy-filled guess", %{conn: conn, user: user} do
      put_press_picture(user, alt: "Portraet")

      html = conn |> de() |> get(~p"/#{user}/media-kit") |> html_response(200)

      assert html =~ "Media Kit von Ada King"
      assert html =~ "Zur freien redaktionellen Verwendung mit Bildnachweis."
      assert html =~ "Ada King · Media Kit"
    end

    test "the editor and its settings row are German", %{conn: conn} do
      {conn, _member} = conn |> de() |> create_and_login_user()

      assert conn |> get(~p"/settings") |> html_response(200) =~ "Media Kit"

      {:ok, _live, html} = live(conn, ~p"/settings/media-kit")

      assert html =~ "Media Kit"
      # The `.po` fuzzy-fill would have kept the old German here.
      refute html =~ "Pressemappe"
    end

    test "the profile card is German", %{conn: conn, user: user} do
      put_press_picture(user)

      html = conn |> de() |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "Das ganze Media Kit"
    end
  end

  describe "/system/media-kit is vutuv's own and did not move" do
    test "it still answers, untouched", %{conn: conn} do
      assert conn |> get(~p"/system/media-kit") |> html_response(200) =~ "Media Kit"
    end
  end
end
