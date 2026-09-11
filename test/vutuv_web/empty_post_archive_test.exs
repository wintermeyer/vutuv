defmodule VutuvWeb.EmptyPostArchiveTest do
  @moduledoc """
  An empty post archive tells a crawler it is not worth keeping (issue #2172).

  Every member has `/<username>/posts` whether or not they ever wrote a line,
  and almost nobody has: **5,941 of 6,025** archives in the dev copy of
  production list nothing for an anonymous reader (measured 2026-09-11). Each
  answered 200 with an empty state and no `x-robots-tag` at all, and
  `/llms.txt` published the bare `/<username>/posts` pattern — close to 30,000
  addresses with the agent siblings, worth reading once and never again.

  The Media Kit had the same shape one URL family over (issue #2143) and this
  is its answer, with three differences the archive brings of its own:

    * **whose emptiness.** A post can be visible to some readers and not
      others, so "empty" depends on who asks. The header speaks to a crawler
      and a crawler is anonymous, so `Vutuv.Posts.public_archive_empty?/2`
      always asks with `viewer = nil` — on the owner's own request too. An
      archive holding nothing but members-only posts says `noindex` to its
      owner, because that is what the page says to everyone it is crawled by.
      Emptiness is ored onto the member's own axes
      (`PostDoc.archive_robots_axes/2`), never written over them, so an empty
      archive whose author also excluded machines carries **both** directives;
    * **a reshare is content.** Two of the 84 non-empty archives hold no post
      of their own at all, only reposts, so a rule reading "has this member
      written a post" would have noindexed a page with entries on it;
    * **the period pages and the `.xml` sibling.** The archive scopes to a
      year / month / day, and each scope is its own address that can be empty
      while the archive is not. The unscoped `.xml` is a 301 to the member's
      RSS feed, so the unscoped path has four surfaces and a period-scoped one
      five.

  `?type=` and `?page=` are deliberately *not* in the derivation: both are
  query strings on the same address, `rel="canonical"` already points them at
  the plain path, and the four documents there ignore them — so a filter with
  nothing under it must not make the page disagree with its own `.md`.

  Calibrated against the un-fixed code: every `== ["noindex"]` below is `[]`
  there, the `.md` frontmatter carries no `noindex: true`, and the `/llms.txt`
  test fails on the sentence that is not in the file yet.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Repo

  # `.xml` is absent on purpose — see the moduledoc. The period-scoped tests
  # below add it back.
  @formats ~w(.md .txt .json)

  defp de(conn), do: put_req_header(conn, "accept-language", "de-DE,de;q=0.9")

  defp robots(conn), do: get_resp_header(conn, "x-robots-tag")

  setup do
    {:ok,
     user: insert_activated_user(username: "leeres.archiv", first_name: "Ada", last_name: "King")}
  end

  describe "an empty archive" do
    test "still answers 200 to a stranger and to its owner", %{conn: conn, user: user} do
      assert conn |> get(~p"/#{user}/posts") |> html_response(200) =~ "Nothing here yet."

      {owner_conn, owner} = create_and_login_user(conn)

      assert owner_conn |> get(~p"/#{owner}/posts") |> html_response(200) =~ "Nothing here yet."
    end

    test "and says so in German", %{conn: conn, user: user} do
      html = conn |> de() |> get(~p"/#{user}/posts") |> html_response(200)

      assert html =~ "Hier gibt es noch nichts."
      assert html =~ "Beiträge von Ada King"
    end

    test "carries noindex in the header and in the meta tag", %{conn: conn, user: user} do
      conn = get(conn, ~p"/#{user}/posts")

      assert robots(conn) == ["noindex"]
      assert html_response(conn, 200) =~ ~s(<meta name="robots" content="noindex")
    end

    test "carries it in the agent documents too", %{conn: conn, user: user} do
      for format <- @formats do
        sibling = get(conn, "/#{user.username}/posts#{format}")

        assert sibling.status == 200, "#{format} answered #{sibling.status}"
        assert robots(sibling) == ["noindex"], "#{format} carried #{inspect(robots(sibling))}"

        assert get_resp_header(sibling, "content-signal") == [
                 "ai-train=yes, search=no, ai-input=yes"
               ]
      end
    end

    test "and the document body says it, without ever serving HTML", %{conn: conn, user: user} do
      markdown = get(conn, "/#{user.username}/posts.md")

      assert ["text/markdown; charset=utf-8"] = get_resp_header(markdown, "content-type")
      refute markdown.resp_body =~ "<!doctype html"
      # The frontmatter is where a `.md` reader meets the flag; `.json` speaks
      # through the headers alone.
      assert markdown.resp_body =~ "noindex: true"
      refute markdown.resp_body =~ "noai: true"

      doc = conn |> get("/#{user.username}/posts.json") |> json_response(200)

      assert doc["total"] == 0
      assert doc["posts"] == []
    end

    test "never invents the member's AI opt-out, and never overwrites it", %{
      conn: conn,
      user: user
    } do
      assert robots(get(conn, ~p"/#{user}/posts")) == ["noindex"]

      # The composition case: emptiness contributes one axis, the member's own
      # choice the other, and the response carries both.
      Repo.update!(Ecto.Changeset.change(user, noai?: true))

      assert robots(get(conn, ~p"/#{user}/posts")) == ["noindex, noai, noimageai"]
      assert robots(get(conn, "/#{user.username}/posts.json")) == ["noindex, noai, noimageai"]
    end
  end

  describe "an archive with something on it" do
    test "the first post takes the noindex away, deleting it puts it back", %{
      conn: conn,
      user: user
    } do
      assert robots(get(conn, ~p"/#{user}/posts")) == ["noindex"]

      post = create_post!(user, %{body: "Ada schreibt ihren ersten Beitrag."})

      assert robots(get(conn, ~p"/#{user}/posts")) == []

      for format <- @formats do
        assert robots(get(conn, "/#{user.username}/posts#{format}")) == [],
               "#{format} still says noindex with a post on the page"
      end

      {:ok, _deleted} = Posts.delete_post(post)

      assert robots(get(conn, ~p"/#{user}/posts")) == ["noindex"]
      assert robots(get(conn, "/#{user.username}/posts.json")) == ["noindex"]
    end

    test "a reshare alone is content", %{conn: conn, user: user} do
      author = insert_activated_user(username: "schreiberin")
      post = create_post!(author, %{body: "Ein Beitrag, den jemand teilt."})

      assert robots(get(conn, ~p"/#{user}/posts")) == ["noindex"]

      assert Posts.repost_post(user, post) == :ok

      assert robots(get(conn, ~p"/#{user}/posts")) == []
      assert robots(get(conn, "/#{user.username}/posts.json")) == []
    end

    test "a members-only post is nothing a crawler can see, owner included", %{conn: conn} do
      {owner_conn, owner} = create_and_login_user(conn)

      create_post!(owner, %{body: "Nur für Mitglieder.", denials: [%{"wildcard" => "logged_out"}]})

      # The owner's own page draws the post…
      owner_page = get(owner_conn, ~p"/#{owner}/posts")
      assert html_response(owner_page, 200) =~ "Nur für Mitglieder."
      # …and still says noindex, because the header describes the page a
      # crawler is served, and a crawler is never signed in.
      assert robots(owner_page) == ["noindex"]

      assert robots(get(conn, ~p"/#{owner}/posts")) == ["noindex"]
      assert robots(get(conn, "/#{owner.username}/posts.json")) == ["noindex"]
    end

    # The other direction of the same claim: a page with something on it must
    # not *clear* an axis the member set, which is what a derivation writing
    # over the axes instead of oring into them would do.
    test "a member's own search opt-out still reaches a full archive", %{conn: conn, user: user} do
      create_post!(user, %{body: "Ein Beitrag wie jeder andere."})
      Repo.update!(Ecto.Changeset.change(user, noindex?: true))

      assert robots(get(conn, ~p"/#{user}/posts")) == ["noindex"]
      assert robots(get(conn, "/#{user.username}/posts.json")) == ["noindex"]
    end

    test "a filter with nothing under it does not disagree with its own document", %{
      conn: conn,
      user: user
    } do
      create_post!(user, %{body: "Ein Beitrag, aber keine Antwort."})

      filtered = get(conn, ~p"/#{user}/posts?#{[type: "replies"]}")

      assert html_response(filtered, 200) =~ "No replies yet."
      assert robots(filtered) == []
      # …because `?type=` is a view of the same address, and the page says so.
      assert filtered.resp_body =~ ~s(rel="canonical")
      assert filtered.resp_body =~ ~s(/#{user.username}/posts")
    end
  end

  describe "a period-scoped archive" do
    setup %{user: user} do
      post = create_post!(user, %{body: "Ein Beitrag aus diesem Jahr."})
      {:ok, year: post.published_on.year}
    end

    test "an empty year says noindex while the year with the post does not", %{
      conn: conn,
      user: user,
      year: year
    } do
      empty_year = year - 3

      assert robots(get(conn, ~p"/#{user}/posts/#{year}")) == []
      assert robots(get(conn, ~p"/#{user}/posts/#{empty_year}")) == ["noindex"]
    end

    test "and all five surfaces of that year agree", %{conn: conn, user: user, year: year} do
      empty = "/#{user.username}/posts/#{year - 3}"

      assert html_response(get(conn, empty), 200) =~ ~s(<meta name="robots" content="noindex")

      for format <- @formats ++ [".xml"] do
        sibling = get(conn, empty <> format)

        assert sibling.status == 200, "#{format} answered #{sibling.status}"
        assert robots(sibling) == ["noindex"], "#{format} carried #{inspect(robots(sibling))}"
      end
    end
  end

  describe "what a machine is told to walk" do
    test "/llms.txt says most members have written nothing and names the sitemap", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> Map.fetch!(:resp_body)

      assert body =~ "/<username>/posts"
      assert body =~ "Most members have written nothing"
      assert body =~ "sitemap"
    end

    test "every archive the sitemap's posts chunk points into answers without noindex", %{
      conn: conn,
      user: user
    } do
      writer = insert_activated_user(username: "schreiberin")
      create_post!(writer, %{body: "Ein öffentlicher Beitrag."})

      slugs =
        Vutuv.Sitemap.post_entries(1)
        |> Enum.map(fn {path, _date} -> path |> String.split("/", trim: true) |> hd() end)
        |> Enum.uniq()

      assert writer.username in slugs
      refute user.username in slugs

      for slug <- slugs do
        assert robots(get(conn, "/#{slug}/posts")) == [],
               "the sitemap lists a post of #{slug}, whose archive says noindex"
      end
    end
  end
end
