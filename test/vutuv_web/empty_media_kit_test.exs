defmodule VutuvWeb.EmptyMediaKitTest do
  @moduledoc """
  An empty Media Kit tells a crawler it is not worth keeping (issue #2143).

  Every member and every page has a Media Kit address whether or not anybody
  ever put something on it, and on the day this was written **all** of them were
  empty: 6,025 members and 12 pages in the dev copy of production, 0 press
  pictures and 0 bios between them. Nothing on the site links an empty one and
  the sitemap leaves it out, but `/llms.txt` published the bare
  `/<username>/media-kit` pattern, so an assistant reading that document walked
  6,037 pages — 30,185 with the four agent siblings — that each answered 200 and
  said nothing, with no `x-robots-tag` at all.

  The answer these tests hold:

    * an empty kit keeps its **200**. The page belongs to its owner, who is
      about to upload; a 404 would make its existence depend on its content and
      would answer a machine's "does this member offer press material?" with an
      error where a 200 answers "no";
    * it carries `noindex` — the response header, the page's own `<meta>` tag
      and every one of the four documents, from the one derivation
      (`Vutuv.PressKit.robots_axes/2`), because a page that says one thing in
      its header and another in its markup is the failure `PostDoc.robots_axes/2`
      is named after;
    * **only** the noindex axis. Emptiness is a statement about worth, not the
      member's stance on machine use, so an empty kit never invents `noai`;
    * the moment there is a picture or a bio the `noindex` is gone, which is the
      one thing that must not break;
    * and `/llms.txt` no longer advertises the pattern as if everybody had one.

  Calibrated against the un-fixed code: every `assert … == ["noindex"]` below is
  `[]` there, `/llms.txt` fails on "Most members and pages have none", and both
  sitemap tests fail because the old query had no `press` chunk to answer with.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.ImageHelpers, only: [put_press_picture: 1, put_press_picture: 2]

  alias Vutuv.PressKit
  alias Vutuv.Repo

  @formats ~w(.md .txt .json .xml)

  defp de(conn), do: put_req_header(conn, "accept-language", "de-DE,de;q=0.9")

  defp robots(conn), do: get_resp_header(conn, "x-robots-tag")

  setup do
    {:ok,
     user: insert_activated_user(username: "leeres.kit", first_name: "Ada", last_name: "King")}
  end

  describe "an empty member kit" do
    test "still answers 200 to its owner and to a stranger", %{conn: conn, user: user} do
      assert conn |> get(~p"/#{user}/media-kit") |> html_response(200) =~ "Nothing here yet."

      {owner_conn, owner} = create_and_login_user(conn)

      assert owner_conn |> get(~p"/#{owner}/media-kit") |> html_response(200) =~
               "Nothing here yet."
    end

    test "and says so in German", %{conn: conn, user: user} do
      html = conn |> de() |> get(~p"/#{user}/media-kit") |> html_response(200)

      assert html =~ "Hier gibt es noch nichts."
      assert html =~ "Media Kit von Ada King"
    end

    test "carries noindex in the header and in the meta tag", %{conn: conn, user: user} do
      conn = get(conn, ~p"/#{user}/media-kit")

      assert robots(conn) == ["noindex"]
      assert html_response(conn, 200) =~ ~s(<meta name="robots" content="noindex")
    end

    test "carries it in all four agent formats too", %{conn: conn, user: user} do
      for format <- @formats do
        sibling = get(conn, "/#{user.username}/media-kit#{format}")

        assert sibling.status == 200, "#{format} answered #{sibling.status}"
        assert robots(sibling) == ["noindex"], "#{format} carried #{inspect(robots(sibling))}"

        assert get_resp_header(sibling, "content-signal") == [
                 "ai-train=yes, search=no, ai-input=yes"
               ]
      end
    end

    test "and the document body says it, without ever serving HTML", %{conn: conn, user: user} do
      markdown = get(conn, "/#{user.username}/media-kit.md")

      assert ["text/markdown; charset=utf-8"] = get_resp_header(markdown, "content-type")
      refute markdown.resp_body =~ "<!doctype html"
      # The frontmatter, which is where a `.md` reader meets the flag — the
      # `.json` renderer drops it and speaks through the headers alone.
      assert markdown.resp_body =~ "noindex: true"
      refute markdown.resp_body =~ "noai: true"

      doc = conn |> get("/#{user.username}/media-kit.json") |> json_response(200)

      assert doc["total"] == 0
      assert doc["photos"] == []
    end

    test "never invents the member's AI opt-out", %{conn: conn, user: user} do
      assert robots(get(conn, ~p"/#{user}/media-kit")) == ["noindex"]

      Repo.update!(Ecto.Changeset.change(user, noai?: true))

      assert robots(get(conn, ~p"/#{user}/media-kit")) == ["noindex, noai, noimageai"]
    end
  end

  describe "a kit that has something" do
    test "one released picture takes the noindex away", %{conn: conn, user: user} do
      assert robots(get(conn, ~p"/#{user}/media-kit")) == ["noindex"]

      put_press_picture(user)

      assert robots(get(conn, ~p"/#{user}/media-kit")) == []

      for format <- @formats do
        assert robots(get(conn, "/#{user.username}/media-kit#{format}")) == []
      end
    end

    test "a written bio alone is content as well", %{conn: conn, user: user} do
      {:ok, _bio} = PressKit.save_bio(user, user, %{"short" => "Ada King schreibt über Zahlen."})

      assert robots(get(conn, ~p"/#{user}/media-kit")) == []
      assert robots(get(conn, "/#{user.username}/media-kit.json")) == []
    end

    test "a member's own search opt-out still reaches a full kit", %{conn: conn, user: user} do
      put_press_picture(user)
      Repo.update!(Ecto.Changeset.change(user, noindex?: true))

      assert robots(get(conn, ~p"/#{user}/media-kit")) == ["noindex"]
    end

    test "a picture still in the AI queue: the page draws a stand-in, the document lists nothing",
         %{conn: conn, user: user} do
      put_press_picture(user, moderation: "pending")

      # The page has a tile and a heading on it, so it is not an empty page…
      assert robots(get(conn, ~p"/#{user}/media-kit")) == []
      # …while a document may only name a file a crawler can actually fetch, and
      # a download URL that answers 404 is not content. Each surface answers
      # `empty?/2` about what it itself carries; this minutes-long window is the
      # only place the two differ.
      assert robots(get(conn, "/#{user.username}/media-kit.json")) == ["noindex"]
    end
  end

  describe "a page's kit answers the same way" do
    setup do
      {:ok, organization: insert(:organization, name: "Acme GmbH")}
    end

    test "empty says noindex, a picture takes it away", %{conn: conn, organization: organization} do
      path = "/organizations/#{organization.slug}/media-kit"

      assert conn |> get(path) |> html_response(200) =~ "Nothing here yet."
      assert robots(get(conn, path)) == ["noindex"]
      assert robots(get(conn, path <> ".json")) == ["noindex"]

      put_press_picture(organization)

      assert robots(get(conn, path)) == []
      assert robots(get(conn, path <> ".json")) == []
    end
  end

  describe "what a machine is told to walk" do
    test "/llms.txt says most members have none and names the sitemap", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> Map.fetch!(:resp_body)

      assert body =~ "/<username>/media-kit"
      assert body =~ "sitemap"
      assert body =~ "Most members and pages have none"
    end

    test "a bio-only kit joins the sitemap, an empty one stays out", %{conn: conn, user: user} do
      writer = insert_activated_user(username: "nur.text")
      {:ok, _bio} = PressKit.save_bio(writer, writer, %{"medium" => "Hundert Wörter über mich."})

      index = conn |> get(~p"/sitemap.xml") |> Map.fetch!(:resp_body)
      assert index =~ "/sitemaps/press-1.xml"

      chunk = conn |> get(~p"/sitemaps/press-1.xml") |> Map.fetch!(:resp_body)
      assert chunk =~ "/#{writer.username}/media-kit"
      refute chunk =~ "/#{user.username}/media-kit"
    end

    test "nothing the sitemap lists answers noindex", %{conn: conn, user: user} do
      put_press_picture(user)
      writer = insert_activated_user(username: "nur.text")
      {:ok, _bio} = PressKit.save_bio(writer, writer, %{"long" => "Sehr viele Wörter über mich."})

      chunk = conn |> get(~p"/sitemaps/press-1.xml") |> Map.fetch!(:resp_body)

      paths = Regex.scan(~r{<loc>[^<]*(/[^/<]+/media-kit)</loc>}, chunk, capture: :all_but_first)

      assert length(paths) == 2

      for [path] <- paths do
        assert robots(get(conn, path)) == [], "#{path} is in the sitemap and says noindex"
      end
    end
  end
end
