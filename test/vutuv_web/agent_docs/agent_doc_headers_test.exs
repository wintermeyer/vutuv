defmodule VutuvWeb.AgentDocHeadersTest do
  @moduledoc """
  The HTTP caching headers on agent-document responses: every doc is the
  anonymous public view, so it is publicly cacheable, and Accept-negotiated
  responses name their canonical extension URL via `Content-Location` (the
  markdown-source-endpoints convention). Format plumbing and the negotiation
  itself live in agent_format_test.exs.
  """

  use VutuvWeb.ConnCase, async: true

  setup do
    user = insert_activated_user(username: "header_tester", first_name: "Hedda")
    %{user: user}
  end

  describe "Cache-Control" do
    test "every agent format is publicly cacheable" do
      for extension <- ~w(.md .txt .json .vcf) do
        conn = get(build_conn(), "/header_tester" <> extension)

        assert conn.status == 200

        assert get_resp_header(conn, "cache-control") == ["public, max-age=300"],
               "missing cache policy on #{extension}"
      end
    end

    test "content types carry an explicit charset" do
      conn = get(build_conn(), "/header_tester.md")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type == "text/markdown; charset=utf-8"
    end
  end

  describe "Content-Location" do
    test "an Accept-negotiated response names its canonical extension URL" do
      conn =
        build_conn()
        |> put_req_header("accept", "text/markdown")
        |> get("/header_tester")

      assert conn.status == 200
      assert get_resp_header(conn, "content-location") == ["/header_tester.md"]
    end

    test "the query string is carried into Content-Location" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/header_tester?lang=de")

      assert conn.status == 200
      assert get_resp_header(conn, "content-location") == ["/header_tester.json?lang=de"]
    end

    test "an extension URL self-identifies and sends no Content-Location" do
      conn = get(build_conn(), "/header_tester.md")

      assert conn.status == 200
      assert get_resp_header(conn, "content-location") == []
    end
  end
end
