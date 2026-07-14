defmodule VutuvWeb.DevDocControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth.Scopes

  test "the docs pages render with curl examples, no login needed", %{conn: conn} do
    response = conn |> get(~p"/developers") |> html_response(200)
    assert response =~ "vutuv API"
    assert response =~ "curl"
    assert response =~ "/api/2.0/me"

    for page <- ["authentication", "reference"] do
      response = conn |> get("/developers/#{page}") |> html_response(200)
      assert response =~ "curl"
    end

    assert conn |> get("/developers/webhooks") |> html_response(200) =~ "X-Vutuv-Signature"
  end

  test "every page serves its raw Markdown under .md", %{conn: _conn} do
    for path <- [
          "/developers.md",
          "/developers/authentication.md",
          "/developers/cookbook.md",
          "/developers/data-model.md",
          "/developers/reference.md",
          "/developers/webhooks.md"
        ] do
      conn = get(build_conn(), path)
      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/markdown"
      assert conn.resp_body =~ ~r/^# /
    end
  end

  test "the cookbook answers the basic how-do-I questions with runnable curl", %{conn: conn} do
    response = conn |> get("/developers/cookbook") |> html_response(200)

    # The recipes the docs must answer concretely: posting and direct
    # messages ($API is the base-URL shorthand the page defines up top).
    assert response =~ "https://vutuv.de/api/2.0"
    assert response =~ "$API/posts"
    assert response =~ "/messages"
    assert response =~ "$API/conversations"
    assert response =~ "curl"
  end

  test "the data model page describes the entities and their relationships", %{conn: conn} do
    body = get(conn, "/developers/data-model.md").resp_body

    # The entities a third-party developer works with...
    for entity <- ["member", "post", "conversation", "tag", "follow", "connection"] do
      assert body =~ ~r/#{entity}/i, "data model page does not mention #{entity}"
    end

    # ...and the load-bearing concepts.
    assert body =~ "UUID"
    assert body =~ ~r/denial/i
    assert body =~ ~r/endorsement/i
  end

  test "the overview explains where development happens and how to report bugs", %{conn: conn} do
    response = conn |> get(~p"/developers") |> html_response(200)
    assert response =~ "github.com/wintermeyer/vutuv"
    assert response =~ "github.com/wintermeyer/vutuv/issues"
  end

  test "the overview welcomes contributors: pull requests and feature requests", %{conn: conn} do
    response = conn |> get(~p"/developers") |> html_response(200)
    # The page should read as an invitation to participate, not just a spec.
    assert response =~ ~r/pull request/i
    assert response =~ ~r/feature request/i
  end

  test "the overview points readers at the RSS feeds", %{conn: conn} do
    # Power users get a no-account, no-token way in: the site-wide and
    # per-member RSS feeds, linked straight from the developer front door.
    response = conn |> get(~p"/developers") |> html_response(200)
    assert response =~ ~r/rss/i
    assert response =~ ~p"/posts/feed.xml"
  end

  test "the overview shows you need a token and exactly how to get one", %{conn: conn} do
    response = conn |> get(~p"/developers") |> html_response(200)

    # Where the token is made, and the no-account-yet path to get there.
    assert response =~ ~p"/access_tokens"
    assert response =~ ~p"/login"
    # The exact on-screen button label, the token shape, and the starter
    # scope, so the documented click-path matches the real form.
    assert response =~ "Create an access token"
    assert response =~ "vutuv_pat_"
    assert response =~ "profile:read"
  end

  test "the overview gives a no-token, no-signup example to play with", %{conn: conn} do
    response = conn |> get(~p"/developers") |> html_response(200)
    assert response =~ "curl https://vutuv.de/wintermeyer.json"
  end

  test "every internal link in the developer docs resolves (page and anchor)", %{conn: conn} do
    # The user's hard requirement: no dead links in the docs. The body links
    # are plain Markdown strings (unlike the template's compile-checked ~p
    # links), so they are the ones that rot. Auth-gated targets (access
    # tokens, apps, connected apps) 404 for anonymous callers, so check while
    # logged in.
    {conn, _user} = create_and_login_user(conn)

    for page <- dev_doc_pages(),
        {path, fragment} <- internal_links(dev_doc_markdown(page)) do
      resp = get(recycle(conn), path)

      assert resp.status in [200, 302],
             "broken link #{path} in #{page}.md returned #{resp.status}"

      if fragment do
        assert resp.status == 200,
               "anchor link #{path}##{fragment} in #{page}.md did not reach an HTML page"

        assert resp.resp_body =~ ~s(id="#{fragment}"),
               "broken anchor #{path}##{fragment} in #{page}.md: nothing on the page has that id"
      end
    end
  end

  test "every docs page links every other docs page in the nav", %{conn: conn} do
    response = conn |> get(~p"/developers") |> html_response(200)

    for page <- ["authentication", "cookbook", "data-model", "reference", "jobs", "webhooks"] do
      assert response =~ "/developers/#{page}", "docs nav is missing #{page}"
    end
  end

  test "a logged-in developer gets quick links to their credential pages", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    response = conn |> get(~p"/developers") |> html_response(200)

    # The chrome surfaces the three places credentials actually live, so a
    # developer reading the docs does not have to dig through profile settings.
    assert response =~ "Your access tokens"
    assert response =~ "Your apps"
    assert response =~ ~p"/access_tokens"
    assert response =~ ~p"/connected_apps"
  end

  test "logged-out visitors do not see the credential quick links", %{conn: conn} do
    response = conn |> get(~p"/developers") |> html_response(200)
    refute response =~ "Your access tokens"
    refute response =~ "Your apps"
  end

  test "unknown pages 404", %{conn: conn} do
    assert get(conn, "/developers/nonsense").status == 404
  end

  test "the scope table in the docs matches the real scope list", %{conn: conn} do
    body = get(conn, "/developers/authentication.md").resp_body

    for scope <- Scopes.all() do
      assert body =~ "`#{scope}`", "scope #{scope} is missing from the documentation"
    end
  end

  test "llms.txt points agents at the API docs", %{conn: conn} do
    body = get(conn, "/llms.txt").resp_body
    assert body =~ "/developers"
    assert body =~ "/api/2.0"
    assert body =~ "/developers/cookbook.md"
    assert body =~ "/developers/data-model.md"
  end

  # Every dev-doc slug, including the overview ("index"). doc_pages/0 is the
  # registry minus index, so prepend it.
  defp dev_doc_pages, do: ["index" | VutuvWeb.DevDocController.doc_pages()]

  defp dev_doc_markdown(page), do: File.read!("priv/dev_docs/#{page}.md")

  # Every internal Markdown link in the source: [text](/path) or
  # [text](/path#anchor). Only paths that start with "/" (site-relative), so
  # external https:// links and mailto: are skipped. Returns {path, fragment}.
  defp internal_links(markdown) do
    ~r/\]\((\/[^)\s#]*)(#[^)\s]*)?\)/
    |> Regex.scan(markdown)
    |> Enum.map(fn
      [_full, path, "#" <> fragment] -> {path, fragment}
      [_full, path, _empty] -> {path, nil}
      [_full, path] -> {path, nil}
    end)
    |> Enum.uniq()
  end
end
