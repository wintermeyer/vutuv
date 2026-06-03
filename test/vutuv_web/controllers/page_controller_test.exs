defmodule VutuvWeb.PageControllerTest do
  use VutuvWeb.ConnCase, async: true

  describe "GET /robots.txt" do
    test "is served as plain text with a 200" do
      conn = get(build_conn(), "/robots.txt")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"
    end

    test "welcomes crawlers but fences off private and auth areas" do
      body = build_conn() |> get("/robots.txt") |> response(200)

      # Public content stays crawlable.
      assert body =~ "User-agent: *"
      assert body =~ "Allow: /"

      # Sensitive or backstage paths must never be indexed.
      assert body =~ "Disallow: /admin/"
      assert body =~ "Disallow: /sessions"
      assert body =~ "Disallow: /api/"
    end
  end
end
