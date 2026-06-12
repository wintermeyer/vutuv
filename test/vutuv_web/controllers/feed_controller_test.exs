defmodule VutuvWeb.FeedControllerTest do
  @moduledoc """
  The RSS 2.0 feeds: one per member (/:slug/posts/feed.xml, original posts
  only) and the site-wide firehose (/posts/feed.xml). Full item content
  per the agent-readiness spec — readers and agents get the whole post,
  not a teaser. Served outside the browser pipeline (a reader sending
  `Accept: application/rss+xml` must not be 406'd away).
  """

  use VutuvWeb.ConnCase, async: true

  import Vutuv.PostsHelpers

  @base "http://localhost:4001"

  setup do
    author = insert_activated_user(active_slug: "feed_author", first_name: "Fiona")
    %{author: author}
  end

  describe "GET /:slug/posts/feed.xml" do
    test "answers RSS even to a reader that only accepts application/rss+xml", %{author: author} do
      create_post!(author, %{"body" => "Hello feed"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/rss+xml")
        |> get("/feed_author/posts/feed.xml")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/rss+xml"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
      assert conn.resp_body =~ ~s(<rss version="2.0")
      assert conn.resp_body =~ "<title>Fiona Test · vutuv</title>"
    end

    test "items carry the full rendered content, not a teaser", %{author: author} do
      create_post!(author, %{"body" => "Hello **world**\n\nSecond paragraph."})

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> response(200)

      assert body =~ "<content:encoded><![CDATA["
      assert body =~ "<strong>world</strong>"
      assert body =~ "Second paragraph."
    end

    test "links and guids are absolute permalinks", %{author: author} do
      post = create_post!(author, %{"body" => "Linked"})

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> response(200)

      assert body =~ "<link>#{@base}/feed_author/posts/#{post.id}</link>"
      assert body =~ ~s(<guid isPermaLink="true">#{@base}/feed_author/posts/#{post.id}</guid>)
      assert body =~ ~s(<atom:link href="#{@base}/feed_author/posts/feed.xml" rel="self")
    end

    test "root-relative URLs in the rendered body become absolute", %{author: author} do
      create_post!(author, %{"body" => "See [the tags](/tags) page"})

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> response(200)

      assert body =~ ~s(href="#{@base}/tags")
    end

    test "pubDate is RFC 1123", %{author: author} do
      create_post!(author, %{"body" => "Dated"})

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> response(200)

      assert body =~ ~r|<pubDate>\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT</pubDate>|
    end

    test "restricted posts and other members' posts stay out", %{author: author} do
      other = insert_activated_user(active_slug: "other_member")
      visible = create_post!(author, %{"body" => "Mine, public"})

      restricted =
        create_post!(author, %{
          "body" => "Mine, restricted",
          "denials" => [%{"wildcard" => "everyone"}]
        })

      foreign = create_post!(other, %{"body" => "Not mine"})

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> response(200)

      assert body =~ visible.id
      refute body =~ restricted.id
      refute body =~ foreign.id
    end

    test "an unknown or unactivated member 404s" do
      insert(:user, active_slug: "sleepy_member")

      assert get(build_conn(), "/nobody_here/posts/feed.xml").status == 404
      assert get(build_conn(), "/sleepy_member/posts/feed.xml").status == 404
    end

    test "a noindexed member's feed serves, marked noindex, AI choice intact" do
      quiet = insert_activated_user(active_slug: "quiet_author", noindex?: true, noai?: false)
      create_post!(quiet, %{"body" => "Quiet words"})

      conn = get(build_conn(), "/quiet_author/posts/feed.xml")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
      assert get_resp_header(conn, "content-signal") == ["ai-train=yes, search=no, ai-input=yes"]
    end

    test "an AI-opted-out member's feed serves with the noai directives" do
      human = insert_activated_user(active_slug: "human_author", noindex?: false, noai?: true)
      create_post!(human, %{"body" => "For people"})

      conn = get(build_conn(), "/human_author/posts/feed.xml")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == ["noai, noimageai"]
      assert get_resp_header(conn, "content-signal") == ["ai-train=no, search=yes, ai-input=no"]
    end
  end

  describe "GET /posts/feed.xml" do
    test "collects the latest public posts across members", %{author: author} do
      other = insert_activated_user(active_slug: "second_author")
      mine = create_post!(author, %{"body" => "From Fiona"})
      theirs = create_post!(other, %{"body" => "From the other one"})

      conn = get(build_conn(), "/posts/feed.xml")

      assert conn.status == 200
      assert conn.resp_body =~ mine.id
      assert conn.resp_body =~ theirs.id
      assert get_resp_header(conn, "content-signal") == ["ai-train=yes, search=yes, ai-input=yes"]
    end

    # The aggregate feed carries one all-yes Content-Signal and cannot
    # signal per item, so members who opted out (of search engines or of
    # AI use) are left out entirely — same reasoning for both axes.
    test "skips noindexed members, AI-opted-out members and restricted posts", %{author: author} do
      quiet = insert_activated_user(active_slug: "quiet_author", noindex?: true)
      quiet_post = create_post!(quiet, %{"body" => "Quiet words"})

      human = insert_activated_user(active_slug: "human_author", noai?: true)
      human_post = create_post!(human, %{"body" => "For people only"})

      restricted =
        create_post!(author, %{
          "body" => "Restricted words",
          "denials" => [%{"wildcard" => "everyone"}]
        })

      body = build_conn() |> get("/posts/feed.xml") |> response(200)

      refute body =~ quiet_post.id
      refute body =~ human_post.id
      refute body =~ restricted.id
    end
  end

  describe "feed discovery in the HTML head" do
    test "the profile page advertises the member's feed", %{author: author} do
      create_post!(author, %{"body" => "Discoverable"})

      html = build_conn() |> get("/feed_author") |> html_response(200)

      assert html =~
               ~s(rel="alternate" type="application/rss+xml" href="/feed_author/posts/feed.xml")
    end

    test "the post archive advertises the member's feed" do
      html = build_conn() |> get("/feed_author/posts") |> html_response(200)

      assert html =~ ~s(href="/feed_author/posts/feed.xml")
    end
  end
end
