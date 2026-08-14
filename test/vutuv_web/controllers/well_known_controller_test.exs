defmodule VutuvWeb.WellKnownControllerTest do
  @moduledoc """
  The /.well-known endpoints: agent-skills discovery (Cloudflare draft
  v0.2.0 — an index.json naming the skill files, each verified by a
  sha256 digest over the exact served bytes), security.txt (RFC 9116) and
  NodeInfo (issue #1448).
  """

  use VutuvWeb.ConnCase, async: true

  describe "GET /.well-known/agent-skills/index.json" do
    test "lists the vutuv skill with a digest matching the served file" do
      conn = get(build_conn(), "/.well-known/agent-skills/index.json")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]

      index = Jason.decode!(conn.resp_body)
      assert index["$schema"] == "https://schemas.agentskills.io/discovery/0.2.0/schema.json"

      assert [skill] = index["skills"]
      assert skill["name"] == "vutuv"
      assert skill["type"] == "skill-md"
      assert skill["description"] =~ "vutuv"
      assert skill["url"] == "http://localhost:4001/.well-known/agent-skills/vutuv/SKILL.md"

      # The digest contract: sha256 over the exact bytes the skill URL serves.
      served = get(build_conn(), "/.well-known/agent-skills/vutuv/SKILL.md").resp_body
      expected = "sha256:" <> Base.encode16(:crypto.hash(:sha256, served), case: :lower)
      assert skill["digest"] == expected
    end
  end

  describe "GET /.well-known/agent-skills/vutuv/SKILL.md" do
    test "serves the skill as Markdown with frontmatter, CORS-open" do
      conn = get(build_conn(), "/.well-known/agent-skills/vutuv/SKILL.md")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type == "text/markdown; charset=utf-8"
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

      assert String.starts_with?(conn.resp_body, "---\nname: vutuv\n")
      assert conn.resp_body =~ "description:"
      # The body teaches the agent the format system and the API.
      assert conn.resp_body =~ ".md"
      assert conn.resp_body =~ "/api/2.0"
    end

    test "the .json/.md suffixes survive the AgentFormat extension stripping" do
      # Without the .well-known skip-prefix these would be rewritten to
      # extension requests and 404 (the routes would never match).
      assert get(build_conn(), "/.well-known/agent-skills/index.json").status == 200
      assert get(build_conn(), "/.well-known/agent-skills/vutuv/SKILL.md").status == 200
    end
  end

  describe "NodeInfo" do
    test "the well-known document links both served schema versions" do
      conn = get(build_conn(), "/.well-known/nodeinfo")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]

      assert %{"links" => links} = Jason.decode!(conn.resp_body)

      assert links == [
               %{
                 "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.1",
                 "href" => "http://localhost:4001/system/nodeinfo/2.1"
               },
               %{
                 "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.0",
                 "href" => "http://localhost:4001/system/nodeinfo/2.0"
               }
             ]
    end

    test "every advertised href really answers a document of that version" do
      %{"links" => links} = Jason.decode!(get(build_conn(), "/.well-known/nodeinfo").resp_body)

      for %{"rel" => rel, "href" => href} <- links do
        version = String.replace_prefix(rel, "http://nodeinfo.diaspora.software/ns/schema/", "")
        conn = get(build_conn(), URI.parse(href).path)

        assert conn.status == 200, "#{href} did not answer"
        assert Jason.decode!(conn.resp_body)["version"] == version
      end
    end

    test "the document carries the schema's required fields" do
      conn = get(build_conn(), "/system/nodeinfo/2.1")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")

      assert content_type ==
               ~s(application/json; profile="http://nodeinfo.diaspora.software/ns/schema/2.1#"; charset=utf-8)

      doc = Jason.decode!(conn.resp_body)

      for key <- ~w(version software protocols services openRegistrations usage metadata) do
        assert Map.has_key?(doc, key), "the 2.1 document is missing #{key}"
      end

      assert doc["software"]["name"] == "vutuv"
      assert doc["software"]["repository"] == "https://github.com/wintermeyer/vutuv"
      assert doc["protocols"] == ["activitypub"]
      assert is_integer(doc["usage"]["users"]["total"])
      assert is_integer(doc["usage"]["localPosts"])
      assert doc["metadata"]["nodeName"] == "vutuv"
    end

    test "a schema version this installation does not serve 404s" do
      assert get(build_conn(), "/system/nodeinfo/1.0").status == 404
      assert get(build_conn(), "/system/nodeinfo/3.0").status == 404
    end

    test "a directory asking for JSON is not diverted into the agent formats" do
      # /system/nodeinfo/2.0 ends in a dot-something, and every consumer sends
      # Accept: application/json — neither may reach VutuvWeb.Plug.AgentFormat's
      # extension stripping or its handled-document 404 guard.
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/system/nodeinfo/2.0")

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["version"] == "2.0"
    end
  end

  describe "security.txt" do
    test "serves RFC 9116 fields under /.well-known and the root alias" do
      for path <- ["/.well-known/security.txt", "/security.txt"] do
        conn = get(build_conn(), path)

        assert conn.status == 200
        assert [content_type] = get_resp_header(conn, "content-type")
        assert content_type =~ "text/plain"

        assert conn.resp_body =~ "Contact: mailto:sw@wintermeyer-consulting.de"
        assert conn.resp_body =~ "Preferred-Languages: en, de"
        assert conn.resp_body =~ "Canonical: http://localhost:4001/.well-known/security.txt"

        [expires] = Regex.run(~r/Expires: (.+)/, conn.resp_body, capture: :all_but_first)
        {:ok, expires, _offset} = DateTime.from_iso8601(expires)
        assert DateTime.after?(expires, DateTime.utc_now())
      end
    end
  end
end
