defmodule VutuvWeb.WebAppManifestTest do
  @moduledoc """
  The installed web app (issue #1464).

  A Home Screen web app decides which links stay *inside* the app from the
  manifest's `scope`: "links outside the scope will open in Safari View
  Controller" (Apple, WWDC23 "What's new in web apps"). vutuv shipped no
  manifest at all, and the member who reported #1464 got that overlay browser
  on every navigation item of the app he had just installed.

  So three things have to hold, and each of them is invisible until somebody
  installs the site: the document links a manifest, the manifest claims the
  whole site as its scope, and its icons resolve to real images (a 404 icon
  costs the install prompt on Android and the Home Screen icon on iOS).

  The `viewport-fit=cover` assertion belongs here rather than with the layout
  tests because it is the same feature: without it `env(safe-area-inset-*)`
  resolves to 0 on every device, so the bottom tab bar cannot reserve the home
  indicator's strip and the safe-area rules in `components.css` are dead code.
  """
  use VutuvWeb.ConnCase, async: true

  @path "/site.webmanifest"

  defp manifest(conn) do
    conn = get(conn, @path)

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  describe "GET /site.webmanifest" do
    test "answers a manifest document", %{conn: conn} do
      conn = get(conn, @path)

      assert conn.status == 200

      assert [content_type] = get_resp_header(conn, "content-type")

      assert String.starts_with?(content_type, "application/manifest+json"),
             "#{@path} answered #{content_type}, which no browser reads as a manifest"
    end

    test "claims the whole site, so no in-app link falls out of the app", %{conn: conn} do
      manifest = manifest(conn)

      assert manifest["scope"] == "/",
             """
             The scope must be the site root. Anything narrower sends every
             link outside it to the in-app browser overlay (issue #1464).
             """

      assert manifest["start_url"] == "/"
      assert manifest["display"] == "standalone"
      assert manifest["id"] == "/"
    end

    test "names this installation rather than hard-coding vutuv", %{conn: conn} do
      manifest = manifest(conn)
      name = Application.fetch_env!(:vutuv, :node_name)

      assert manifest["name"] == name
      assert manifest["short_name"] == name
    end

    test "every declared icon resolves to an image", %{conn: conn} do
      icons = manifest(conn)["icons"]

      assert length(icons) >= 2, "a manifest needs at least the 192 and 512 pixel icons"

      sizes = Enum.map(icons, & &1["sizes"])
      assert "192x192" in sizes
      assert "512x512" in sizes

      assert Enum.any?(icons, &(&1["purpose"] == "maskable")),
             """
             Without a maskable icon Android shrinks the whole square into its
             launcher shape, which reads as a sticker rather than an app icon.
             """

      for icon <- icons do
        response = get(build_conn(), icon["src"])

        assert response.status == 200,
               "the manifest declares #{icon["src"]}, which answered #{response.status}"

        assert [content_type] = get_resp_header(response, "content-type")

        assert String.starts_with?(content_type, "image/"),
               "the manifest declares #{icon["src"]}, which answered #{content_type}"
      end
    end
  end

  describe "the document" do
    setup %{conn: conn} do
      %{html: conn |> get("/") |> html_response(200)}
    end

    test "links the manifest", %{html: html} do
      assert html =~ ~s(rel="manifest"),
             "no <link rel=\"manifest\">, so nothing the manifest declares applies"

      assert html =~ @path
    end

    test "opts the viewport into the display cutout", %{html: html} do
      assert [_, viewport] = Regex.run(~r/name="viewport" content="([^"]+)"/, html)

      assert viewport =~ "viewport-fit=cover",
             """
             Without `viewport-fit=cover` every `env(safe-area-inset-*)` is 0,
             so the tab bar cannot reserve the home indicator's strip.
             """
    end
  end
end
