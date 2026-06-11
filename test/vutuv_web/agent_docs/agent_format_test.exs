defmodule VutuvWeb.AgentFormatTest do
  @moduledoc """
  The agent-format plumbing: URL extensions (.md/.txt/.json/.vcf), Accept
  negotiation, the response headers and the "an unsupported extension never
  serves HTML" guard. Content parity lives in agent_docs_drift_test.exs.
  """

  use VutuvWeb.ConnCase, async: true

  setup do
    user = insert_activated_user(active_slug: "agent_tester", first_name: "Agatha")
    %{user: user}
  end

  describe "URL extensions" do
    test "/:slug.md answers Markdown with the agent headers" do
      conn = get(build_conn(), "/agent_tester.md")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/markdown"
      assert conn.resp_body =~ "# Agatha Test"
      assert conn.resp_body =~ "schema_version: 1"
      assert get_resp_header(conn, "vary") == ["accept, accept-language"]
      assert get_resp_header(conn, "content-signal") == ["ai-train=yes, search=yes, ai-input=yes"]
      assert [tokens] = get_resp_header(conn, "x-markdown-tokens")
      assert String.to_integer(tokens) > 0
    end

    test "/:slug.txt answers plain text wrapped at 80 columns" do
      conn = get(build_conn(), "/agent_tester.txt")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"
      assert conn.resp_body =~ "Agatha Test"
      assert conn.resp_body =~ "schema_version: 1"

      for line <- String.split(conn.resp_body, "\n"), not (line =~ "http") do
        assert String.length(line) <= 80, "line longer than 80 columns: #{inspect(line)}"
      end
    end

    test "/:slug.json answers a JSON document with schema_version" do
      conn = get(build_conn(), "/agent_tester.json")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      doc = Jason.decode!(conn.resp_body)
      assert doc["type"] == "profile"
      assert doc["schema_version"] == 1
      assert doc["name"] == "Agatha Test"
      assert doc["generated_at"]
      assert doc["formats"]["markdown"] =~ "/agent_tester.md"
    end

    test "/:slug.vcf answers a vCard download" do
      conn = get(build_conn(), "/agent_tester.vcf")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/vcard"
      assert conn.resp_body =~ "BEGIN:VCARD"
      assert conn.resp_body =~ "FN:Agatha Test"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "agatha_test_vcard.vcf"
    end

    test "slugs containing dots keep working, with and without extension" do
      insert_activated_user(active_slug: "stefan.wintermeyer", first_name: "Stefan")

      assert get(build_conn(), "/stefan.wintermeyer") |> html_response(200) =~ "Stefan"
      conn = get(build_conn(), "/stefan.wintermeyer.md")
      assert conn.status == 200
      assert conn.resp_body =~ "# Stefan Test"
    end

    test "an unknown member 404s with extension too" do
      assert get(build_conn(), "/nobody_here.md").status == 404
    end

    test "a verified member's Markdown states it as a fact line, like the text version" do
      insert_activated_user(active_slug: "verified_member", identity_verified?: true)

      body = get(build_conn(), "/verified_member.md").resp_body

      assert body =~ "- Verified profile: yes"
      refute body =~ "✓"
    end

    test "Links and Social Media share the Markdown [label](url) link style", %{user: user} do
      insert(:url, user: user, value: "https://blog.example.org/", description: "Blog")
      insert(:social_media_account, user: user, provider: "GitHub", value: "octocat")
      insert(:social_media_account, user: user, provider: "Snapchat", value: "ghosty")

      body = get(build_conn(), "/agent_tester.md").resp_body

      assert body =~ "- [Blog](https://blog.example.org/)"
      assert body =~ "- [GitHub](https://github.com/octocat)"
      # A provider without a canonical URL scheme has no link to offer.
      assert body =~ "- Snapchat: ghosty"
    end

    test "in-app redirects keep the extension (legacy /users/:slug URL)" do
      conn = get(build_conn(), "/users/agent_tester.md")

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/agent_tester.md"]
    end

    test "a search term ending in a known extension is not mistaken for a format" do
      # /search/:id carried the raw query as the last segment; "search" must be
      # skipped so the plug does not strip a real ".json"/".md" off it. The
      # stored-query URL 301s into the live search; the term must survive
      # intact, not be truncated to "package".
      conn = get(build_conn(), "/search/package.json")
      assert redirected_to(conn, 301) == "/search?q=package.json"
    end

    test "a trailing-slash profile advertises clean alternate URLs" do
      html = get(build_conn(), "/agent_tester/") |> html_response(200)

      assert html =~ ~s(href="/agent_tester.md")
      refute html =~ "/agent_tester/.md"
    end
  end

  describe "escaping and injection" do
    test "the vCard escapes ; , and newlines in user-controlled fields", %{user: user} do
      insert(:address,
        user: user,
        line_1: "Suite 1; Floor 2\nDoor B",
        city: "Foo,Bar",
        country: "Germany"
      )

      body = get(build_conn(), "/agent_tester.vcf").resp_body

      # The data ";" and "," are escaped, so they don't shift the ADR fields.
      assert body =~ "Suite 1\\; Floor 2"
      assert body =~ "Foo\\,Bar"
      # An embedded newline becomes the escaped \n token, never a raw line.
      refute body =~ "Floor 2\nDoor B"
    end

    test "the vCard download filename drops quotes and control chars" do
      insert_activated_user(
        active_slug: "weird_name",
        first_name: ~s(Ann "X"),
        last_name: "Smith"
      )

      conn = get(build_conn(), "/weird_name.vcf")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      # The inner quote must not leak into the quoted-string header.
      refute disposition =~ ~s(ann "x")
      assert disposition =~ "_vcard.vcf"
    end

    test "Markdown escapes link-breaking characters in member names", %{user: target} do
      evil =
        insert_activated_user(first_name: "Eve", last_name: "x](https://evil.example)")

      follow!(evil, target)

      body = get(build_conn(), "/agent_tester/followers.md").resp_body

      # The closing bracket in the name is escaped, so it cannot terminate the
      # link text and smuggle in an attacker URL.
      assert body =~ "x\\]"
      refute body =~ "[Eve x](https://evil.example)"
    end

    test "YAML frontmatter keeps interpolation-looking text literal", %{user: _user} do
      insert(:tag, name: "Sharp", slug: "sharp", description: ~S(Costs #{n} euros))

      body = get(build_conn(), "/tags/sharp.md").resp_body

      assert body =~ ~S(description: "Costs #{n} euros")
      # inspect/1 would have produced an invalid YAML escape here.
      refute body =~ ~S(\#{n})
    end
  end

  describe "anonymous-view enforcement" do
    test "a moderation-hidden account has no agent documents, even for its owner", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)

      Vutuv.Repo.update_all(
        from(u in Vutuv.Accounts.User, where: u.id == ^me.id),
        set: [frozen_at: NaiveDateTime.utc_now(:second)]
      )

      # The owner still reaches their own frozen HTML profile (banner/review),
      # but the agent formats are the anonymous view and must 404 like everyone.
      assert html_response(get(conn, "/#{me.active_slug}"), 200)
      assert get(conn, "/#{me.active_slug}.md").status == 404
      assert get(conn, "/#{me.active_slug}.json").status == 404
    end

    test "a private email's show page advertises no agent-format alternates", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      private = insert(:email, user: me, public?: false, value: "secret@example.com")

      html = get(conn, "/#{me.active_slug}/emails/#{private.id}") |> html_response(200)

      refute html =~ ~s(rel="alternate")
      assert get(conn, "/#{me.active_slug}/emails/#{private.id}.md").status == 404
    end
  end

  describe "the vCard download affordance" do
    test "the owner downloads the all-emails (session-aware) vCard", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)

      html = get(conn, "/#{me.active_slug}") |> html_response(200)

      assert html =~ ~s(href="/api/1.0/users/#{me.active_slug}/vcard")
    end

    test "an anonymous visitor downloads the public .vcf" do
      html = get(build_conn(), "/agent_tester") |> html_response(200)

      assert html =~ ~s(href="/agent_tester.vcf")
    end
  end

  describe "self-referential URLs" do
    test "a translated doc's own url and sibling links carry the query string" do
      conn = get(build_conn(), "/agent_tester.json?lang=de")
      doc = Jason.decode!(conn.resp_body)

      assert String.ends_with?(doc["url"], "/agent_tester?lang=de")
      assert doc["formats"]["markdown"] =~ "/agent_tester.md?lang=de"
    end
  end

  describe "the unsupported-extension guard" do
    test "a page without agent formats never serves HTML under .md" do
      conn = get(build_conn(), "/community.md")

      assert conn.status == 404
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"
      refute conn.resp_body =~ "<html"
    end

    test "an extension the page does not support 404s (no .vcf for tags)" do
      insert(:tag, name: "Elixir", slug: "elixir")
      assert get(build_conn(), "/tags/elixir.vcf").status == 404
    end

    test "robots.txt and llms.txt are not mistaken for agent formats" do
      conn = get(build_conn(), "/robots.txt")
      assert conn.status == 200
      assert conn.resp_body =~ "User-agent"

      conn = get(build_conn(), "/llms.txt")
      assert conn.status == 200
      assert conn.resp_body =~ ".md"
      assert conn.resp_body =~ "schema_version"
    end
  end

  describe "Accept negotiation" do
    test "Accept: text/markdown on the canonical URL answers Markdown" do
      conn =
        build_conn()
        |> put_req_header("accept", "text/markdown")
        |> get("/agent_tester")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/markdown"
    end

    test "Accept: application/json answers JSON, but text/html wins for browsers" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/agent_tester")

      assert Jason.decode!(conn.resp_body)["type"] == "profile"

      conn =
        build_conn()
        |> put_req_header("accept", "text/html,application/xhtml+xml,application/json;q=0.9")
        |> get("/agent_tester")

      assert html_response(conn, 200) =~ "Agatha"
    end

    test "the HTML page advertises the alternates and varies on Accept" do
      conn = get(build_conn(), "/agent_tester")
      html = html_response(conn, 200)

      assert get_resp_header(conn, "vary") == ["accept"]
      assert html =~ ~s(rel="alternate" type="text/markdown" href="/agent_tester.md")
      assert html =~ ~s(rel="alternate" type="application/json" href="/agent_tester.json")
      assert html =~ ~s(rel="alternate" type="text/vcard" href="/agent_tester.vcf")
      # The visible "Other formats" card links all four siblings.
      assert html =~ ~s(href="/agent_tester.txt")
    end
  end

  describe "the language hint" do
    # The doc content itself stays locale-stable (English unless ?lang= says
    # otherwise); the browser's Accept-Language only adds a final pointer to
    # the translated sibling URL — written in that language — when we have
    # a translation. Declared via Vary: accept-language.

    test "a German browser reading the English Markdown gets a comment pointing to ?lang=de" do
      conn =
        build_conn()
        |> put_req_header("accept-language", "de-DE,de;q=0.9,en;q=0.8")
        |> get("/agent_tester.md")

      assert conn.status == 200

      assert conn.resp_body =~
               "<!-- Diese Seite auf Deutsch: #{VutuvWeb.Endpoint.url()}/agent_tester.md?lang=de -->"

      assert get_resp_header(conn, "vary") == ["accept, accept-language"]
    end

    test "an English browser reading the German text doc gets a bottom line to the English URL" do
      conn =
        build_conn()
        |> put_req_header("accept-language", "en-US,en;q=0.9")
        |> get("/agent_tester.txt?lang=de")

      assert conn.status == 200

      assert String.ends_with?(
               conn.resp_body,
               "This page in English: #{VutuvWeb.Endpoint.url()}/agent_tester.txt\n"
             )
    end

    test "no hint when the browser language matches the rendering" do
      conn =
        build_conn()
        |> put_req_header("accept-language", "de")
        |> get("/agent_tester.md?lang=de")

      assert conn.status == 200
      refute conn.resp_body =~ "<!--"

      conn =
        build_conn()
        |> put_req_header("accept-language", "en-GB")
        |> get("/agent_tester.md")

      refute conn.resp_body =~ "<!--"
    end

    test "no hint for a language we have no translation for, or without the header" do
      conn =
        build_conn()
        |> put_req_header("accept-language", "fr-FR,fr;q=0.9")
        |> get("/agent_tester.md")

      refute conn.resp_body =~ "<!--"

      refute get(build_conn(), "/agent_tester.txt").resp_body =~ "This page in"
    end

    test "other query params survive in the hint URL, JSON stays hint-free" do
      follower = insert_activated_user(first_name: "Fan")
      follow!(follower, insert_activated_user(active_slug: "followed_one"))

      conn =
        build_conn()
        |> put_req_header("accept-language", "de")
        |> get("/followed_one/followers.md?page=1")

      assert conn.resp_body =~ "/followed_one/followers.md?lang=de&page=1 -->"

      conn =
        build_conn()
        |> put_req_header("accept-language", "de")
        |> get("/agent_tester.json")

      refute conn.resp_body =~ "Diese Seite"
      assert get_resp_header(conn, "vary") == ["accept"]
    end
  end

  describe "Content-Signal" do
    test "a noindexed member sends every signal as no, plus x-robots-tag" do
      insert_activated_user(active_slug: "private_person", noindex?: true)

      conn = get(build_conn(), "/private_person.md")

      assert conn.status == 200
      assert get_resp_header(conn, "content-signal") == ["ai-train=no, search=no, ai-input=no"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
    end

    test "the noindexed follow lists send every signal as no", %{user: user} do
      follower = insert_activated_user(first_name: "Fan")
      follow!(follower, user)

      conn = get(build_conn(), "/agent_tester/followers.md")

      assert conn.status == 200
      assert conn.resp_body =~ "Fan Test"
      assert get_resp_header(conn, "content-signal") == ["ai-train=no, search=no, ai-input=no"]
    end
  end
end
