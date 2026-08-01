defmodule VutuvWeb.SiteIconsTest do
  @moduledoc """
  The site icons (`/favicon.ico`, `/favicon.svg`, the Apple touch icons) must
  exist and be served as images.

  This is not cosmetic. iMessage builds its rich link preview with
  `LinkPresentation`, which renders the page and then probes for a site icon —
  `/apple-touch-icon-precomposed.png`, `/apple-touch-icon.png`, `/favicon.ico`.
  When every candidate 404s it abandons the card and shows the bare URL, which
  is what vutuv.de did until this test existed: the layout linked
  `/favicon.ico` while `priv/static/` held no icon file at all, so the link in
  the document 404ed along with everything iOS probed for.

  A 404 here answers with the HTML error page, so asserting the status is not
  enough on its own — a wrong `Plug.Static` `only:` entry would still return
  200 for the error page. Assert the content type is an image.
  """
  use VutuvWeb.ConnCase, async: true

  @icon_paths [
    "/favicon.ico",
    "/favicon.svg",
    "/apple-touch-icon.png",
    "/apple-touch-icon-precomposed.png"
  ]

  describe "icon files" do
    for path <- @icon_paths do
      test "GET #{path} serves an image", %{conn: conn} do
        conn = get(conn, unquote(path))

        assert conn.status == 200

        assert [content_type] = get_resp_header(conn, "content-type")

        assert String.starts_with?(content_type, "image/"),
               "#{unquote(path)} answered #{content_type}, not an image"
      end
    end
  end

  describe "the document's own icon links" do
    test "every icon the layout declares resolves to an image", %{conn: conn} do
      html = conn |> get("/") |> html_response(200)

      hrefs = declared_icon_hrefs(html)

      assert "/favicon.svg" in hrefs
      assert "/favicon.ico" in hrefs
      assert "/apple-touch-icon.png" in hrefs

      for href <- hrefs do
        icon = get(build_conn(), href)

        assert icon.status == 200, "the layout links #{href}, which answered #{icon.status}"

        assert [content_type] = get_resp_header(icon, "content-type")

        assert String.starts_with?(content_type, "image/"),
               "the layout links #{href}, which answered #{content_type}"
      end
    end
  end

  # Every href on a <link rel="..."> whose rel mentions an icon.
  defp declared_icon_hrefs(html) do
    ~r/<link[^>]*>/
    |> Regex.scan(html)
    |> Enum.map(&hd/1)
    |> Enum.filter(&(&1 =~ ~r/rel="[^"]*icon[^"]*"/))
    |> Enum.flat_map(fn tag ->
      case Regex.run(~r/href="([^"]+)"/, tag) do
        [_, href] -> [href]
        nil -> []
      end
    end)
    |> Enum.uniq()
  end
end
