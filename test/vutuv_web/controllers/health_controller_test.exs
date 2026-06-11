defmodule VutuvWeb.HealthControllerTest do
  use VutuvWeb.ConnCase, async: true

  describe "GET /health" do
    test "returns 200 ok as plain text once the app can reach the database" do
      conn = get(build_conn(), "/health")

      assert conn.status == 200
      assert conn.resp_body == "ok"
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"
    end

    test "is not cached by proxies or browsers" do
      conn = get(build_conn(), "/health")

      assert ["no-store"] = get_resp_header(conn, "cache-control")
    end
  end
end
