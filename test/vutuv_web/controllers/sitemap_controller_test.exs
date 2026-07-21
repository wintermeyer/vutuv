defmodule VutuvWeb.SitemapControllerTest do
  @moduledoc """
  The sitemap: an index under /sitemap.xml pointing at chunked child
  sitemaps (users, posts, tags, static pages). Only what an anonymous
  crawler may index appears: activated, indexable members and their
  unrestricted posts.
  """

  use VutuvWeb.ConnCase, async: true

  import Vutuv.PostsHelpers

  @base "http://localhost:4001"

  describe "GET /sitemap.xml" do
    test "answers a sitemap index pointing at the child sitemaps" do
      insert_activated_user()

      conn = get(build_conn(), "/sitemap.xml")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/xml"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]

      assert conn.resp_body =~ "<sitemapindex"
      assert conn.resp_body =~ "#{@base}/sitemaps/static.xml"
      assert conn.resp_body =~ "#{@base}/sitemaps/users-1.xml"
    end

    test "an empty type contributes no child sitemap" do
      conn = get(build_conn(), "/sitemap.xml")

      refute conn.resp_body =~ "posts-1.xml"
      assert conn.resp_body =~ "static.xml"
    end
  end

  describe "GET /sitemaps/users-N.xml" do
    test "lists indexable members with lastmod" do
      user = insert_activated_user(username: "mapped_member")

      conn = get(build_conn(), "/sitemaps/users-1.xml")

      assert conn.status == 200
      assert conn.resp_body =~ "<urlset"
      assert conn.resp_body =~ "<loc>#{@base}/mapped_member</loc>"
      assert conn.resp_body =~ "<lastmod>#{NaiveDateTime.to_date(user.updated_at)}</lastmod>"
    end

    test "excludes unactivated, noindexed and moderation-hidden members" do
      insert(:user, username: "never_activated")
      opted_out = insert_activated_user(noindex?: true)

      insert_activated_user(
        username: "frozen_member",
        frozen_at: NaiveDateTime.utc_now(:second)
      )

      insert_activated_user(username: "visible_member")

      conn = get(build_conn(), "/sitemaps/users-1.xml")

      assert conn.resp_body =~ "/visible_member<"
      refute conn.resp_body =~ "never_activated"
      refute conn.resp_body =~ opted_out.username
      refute conn.resp_body =~ "frozen_member"
    end
  end

  describe "GET /sitemaps/posts-N.xml" do
    test "lists public post permalinks and skips restricted posts" do
      author = insert_activated_user(username: "posting_member")
      post = create_post!(author, %{"body" => "Public words"})

      restricted =
        create_post!(author, %{
          "body" => "Secret words",
          "denials" => [%{"wildcard" => "everyone"}]
        })

      conn = get(build_conn(), "/sitemaps/posts-1.xml")

      assert conn.status == 200
      assert conn.resp_body =~ "<loc>#{@base}/posting_member/posts/#{post.id}</loc>"
      refute conn.resp_body =~ restricted.id
    end

    test "skips posts whose author is unactivated or noindexed" do
      hidden_author = insert_activated_user(username: "quiet_member", noindex?: true)
      hidden_post = create_post!(hidden_author, %{"body" => "Quiet words"})

      conn = get(build_conn(), "/sitemaps/posts-1.xml")

      refute conn.resp_body =~ hidden_post.id
    end
  end

  describe "GET /sitemaps/tags-N.xml" do
    test "lists tag pages" do
      insert(:tag, slug: "elixir-mapped")

      conn = get(build_conn(), "/sitemaps/tags-1.xml")

      assert conn.status == 200
      assert conn.resp_body =~ "<loc>#{@base}/tags/elixir-mapped</loc>"
    end
  end

  describe "GET /sitemaps/static.xml" do
    test "lists the public static pages" do
      conn = get(build_conn(), "/sitemaps/static.xml")

      assert conn.status == 200
      assert conn.resp_body =~ "<loc>#{@base}/</loc>"
      assert conn.resp_body =~ "<loc>#{@base}/community</loc>"
      assert conn.resp_body =~ "<loc>#{@base}/developers</loc>"
      assert conn.resp_body =~ "<loc>#{@base}/listings/most_followed_users</loc>"
    end
  end

  describe "unknown child sitemaps" do
    test "an out-of-range chunk 404s" do
      conn = get(build_conn(), "/sitemaps/users-999.xml")
      assert conn.status == 404
    end

    test "a garbage name 404s" do
      assert get(build_conn(), "/sitemaps/evil.xml").status == 404
      assert get(build_conn(), "/sitemaps/users-0.xml").status == 404
      assert get(build_conn(), "/sitemaps/users-.xml").status == 404
    end
  end
end
