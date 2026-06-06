defmodule VutuvWeb.PostControllerTest do
  @moduledoc """
  The permalink page: public posts are crawlable, restricted posts noindex
  and hide from denied readers, the teaser appears only for the
  non_followers-only case, and the deny list never leaks to readers.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Posts

  @other_login_attrs %{
    "emails" => %{"0" => %{"value" => "other@example.com"}},
    "first_name" => "other"
  }

  # Permalinks resolve through the slugs table (UserResolveSlug), so factory
  # authors need a slug row matching their active_slug.
  defp author(attrs \\ []) do
    user = insert(:user, Keyword.merge([validated?: true], attrs))
    insert(:slug, user: user, value: user.active_slug, disabled: false)
    user
  end

  defp create_post!(author, attrs) do
    {:ok, post} = Posts.create_post(author, attrs)
    post
  end

  defp fresh_conn do
    Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})
  end

  defp pad(int), do: String.pad_leading(Integer.to_string(int), 2, "0")

  describe "GET the permalink" do
    test "renders a public post to anonymous visitors, indexable", %{conn: conn} do
      user = author()
      post = create_post!(user, %{body: "Hello **world**", tags: "elixir"})

      conn = get(conn, Posts.path(post))

      assert html_response(conn, 200) =~ "<strong>world</strong>"
      assert conn.resp_body =~ "elixir"
      assert get_resp_header(conn, "x-robots-tag") == []
    end

    test "redirects non-canonical URLs to the canonical form", %{conn: conn} do
      user = author()
      post = create_post!(user, %{body: "x"})
      date = post.published_on

      # Unpadded date segments and the legacy zero-padded counter both
      # resolve and 302 to the canonical (padded date, plain counter).
      sloppy = "/#{user.active_slug}/posts/#{date.year}/#{date.month}/#{date.day}/#{post.seq}"
      legacy = Posts.path(post) |> String.replace(~r{/(\d+)$}, "/000\\1")

      assert Posts.path(post) =~ ~r|/\d{4}/\d{2}/\d{2}/#{post.seq}$|

      if sloppy != Posts.path(post) do
        assert redirected_to(get(conn, sloppy)) == Posts.path(post)
      end

      assert redirected_to(get(conn, legacy)) == Posts.path(post)
    end

    test "404s for unknown posts and unparseable dates", %{conn: conn} do
      user = author()

      assert get(conn, "/#{user.active_slug}/posts/2026/06/05/0001").status == 404
      assert get(conn, "/#{user.active_slug}/posts/abcd/06/05/0001").status == 404
      assert get(conn, "/#{user.active_slug}/posts/2026/13/05/0001").status == 404
    end

    test "restricted post: 404 for denied readers, 200 + noindex for permitted", %{conn: conn} do
      user = author()
      post = create_post!(user, %{body: "members only", denials: [%{"wildcard" => "logged_out"}]})

      assert get(conn, Posts.path(post)).status == 404

      {member_conn, _member} = create_and_login_user(conn)
      conn = get(member_conn, Posts.path(post))

      assert html_response(conn, 200) =~ "members only"
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
    end

    test "followers-only post: teaser for non-followers, post for followers", %{conn: conn} do
      user = author()

      post =
        create_post!(user, %{
          body: "for my people",
          denials: [%{"wildcard" => "non_followers"}]
        })

      # Anonymous: teaser with a login affordance.
      teaser = get(conn, Posts.path(post))
      assert html_response(teaser, 200) =~ "followers of"
      refute teaser.resp_body =~ "for my people"

      # Logged-in non-follower: teaser with a follow button.
      {visitor_conn, _visitor} = create_and_login_user(fresh_conn())
      teaser = get(visitor_conn, Posts.path(post))
      assert html_response(teaser, 200) =~ "followers of"
      assert teaser.resp_body =~ "connections"
      refute teaser.resp_body =~ "for my people"

      # Follower: the actual post.
      {follower_conn, follower} = create_and_login_user(fresh_conn(), @other_login_attrs)
      insert(:connection, follower: follower, followee: user)
      shown = get(follower_conn, Posts.path(post))
      assert html_response(shown, 200) =~ "for my people"
    end

    test "every other denial shape is a plain 404, never a teaser", %{conn: conn} do
      user = author()
      group = insert(:group, user: user, name: "Geheimbund")

      post =
        create_post!(user, %{
          body: "x",
          denials: [%{"wildcard" => "non_followers"}, %{"group_id" => group.id}]
        })

      conn = get(conn, Posts.path(post))
      assert conn.status == 404
      refute conn.resp_body =~ "followers of"
    end

    test "the deny list shows to the author and never to other readers" do
      {author_conn, author} = create_and_login_user(fresh_conn())
      group = insert(:group, user: author, name: "Geheimbund")
      post = create_post!(author, %{body: "visible", denials: [%{"group_id" => group.id}]})

      own_view = get(author_conn, Posts.path(post))
      assert html_response(own_view, 200) =~ "Hidden from"
      assert own_view.resp_body =~ "Geheimbund"

      # A permitted other reader (logged-in, not in the group) sees the post
      # but neither the summary nor the group name.
      {reader_conn, _reader} = create_and_login_user(fresh_conn(), @other_login_attrs)
      reader_view = get(reader_conn, Posts.path(post))
      assert html_response(reader_view, 200) =~ "visible"
      refute reader_view.resp_body =~ "Hidden from"
      refute reader_view.resp_body =~ "Geheimbund"
    end
  end

  describe "GET /:slug/posts (the author archive)" do
    test "lists the author's posts, visibility-filtered per viewer", %{conn: conn} do
      user = author()
      {:ok, _} = Posts.create_post(user, %{body: "open words"})

      {:ok, _} =
        Posts.create_post(user, %{body: "members words", denials: [%{"wildcard" => "logged_out"}]})

      # Anonymous: only the public post.
      anonymous = get(conn, "/#{user.active_slug}/posts")
      assert html_response(anonymous, 200) =~ "open words"
      refute anonymous.resp_body =~ "members words"

      # A logged-in member sees both.
      {member_conn, _member} = create_and_login_user(conn)
      member_view = get(member_conn, "/#{user.active_slug}/posts")
      assert member_view.resp_body =~ "open words"
      assert member_view.resp_body =~ "members words"
    end

    test "404s for unknown authors", %{conn: conn} do
      assert get(conn, "/no-such-user/posts").status == 404
    end

    test "scopes the archive to a year, month or day", %{conn: conn} do
      user = author()
      {:ok, old} = Posts.create_post(user, %{body: "from last year"})
      {:ok, current} = Posts.create_post(user, %{body: "from today"})

      # Posts are stamped with today's UTC date; backdate one for the test.
      Repo.update_all(
        from(p in Vutuv.Posts.Post, where: p.id == ^old.id),
        set: [published_on: ~D[2025-12-31]]
      )

      today = current.published_on

      year_view = get(conn, "/#{user.active_slug}/posts/2025")
      assert html_response(year_view, 200) =~ "from last year"
      refute year_view.resp_body =~ "from today"

      month_view = get(conn, "/#{user.active_slug}/posts/#{today.year}/#{pad(today.month)}")
      assert month_view.resp_body =~ "from today"
      refute month_view.resp_body =~ "from last year"

      day_view = get(conn, "/#{user.active_slug}/posts/2025/12/31")
      assert day_view.resp_body =~ "from last year"
      refute day_view.resp_body =~ "from today"

      empty_view = get(conn, "/#{user.active_slug}/posts/2024")
      assert html_response(empty_view, 200) =~ "Nothing here yet."
    end

    test "scoped pages carry the trail back up the hierarchy", %{conn: conn} do
      user = author()
      {:ok, post} = Posts.create_post(user, %{body: "crumbed"})
      date = post.published_on

      conn = get(conn, "/#{user.active_slug}/posts/#{date.year}/#{pad(date.month)}/#{pad(date.day)}")

      assert conn.resp_body =~ "All posts"
      assert conn.resp_body =~ ~s(href="/#{user.active_slug}/posts")
      assert conn.resp_body =~ ~s(href="/#{user.active_slug}/posts/#{date.year}")
      assert conn.resp_body =~ ~s(href="/#{user.active_slug}/posts/#{date.year}/#{pad(date.month)}")
    end

    test "404s for nonsense period segments", %{conn: conn} do
      user = author()

      assert get(conn, "/#{user.active_slug}/posts/abcd").status == 404
      assert get(conn, "/#{user.active_slug}/posts/2026/13").status == 404
      assert get(conn, "/#{user.active_slug}/posts/2026/02/30").status == 404
    end
  end

  describe "the profile's View all link" do
    test "appears only when more posts exist than the profile shows", %{conn: conn} do
      user = author()
      for n <- 1..3, do: {:ok, _} = Posts.create_post(user, %{body: "post #{n}"})

      # The exact archive href (closing quote included): permalinks also
      # start with /posts/ but continue with the date segments.
      archive_href = ~s(href="/#{user.active_slug}/posts")

      conn_without = get(conn, "/#{user.active_slug}")
      refute conn_without.resp_body =~ archive_href

      {:ok, _} = Posts.create_post(user, %{body: "post 4"})
      conn_with = get(conn, "/#{user.active_slug}")
      assert conn_with.resp_body =~ archive_href
      assert conn_with.resp_body =~ "View all"
    end
  end

  describe "DELETE /posts/:id" do
    test "the author deletes their post", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "bye"})

      conn = delete(conn, "/posts/#{post.id}")

      assert redirected_to(conn) == "/#{user.active_slug}"
      refute Posts.get_post(post.id)
    end

    test "someone else's post 404s and survives", %{conn: conn} do
      other = author()
      post = create_post!(other, %{body: "not yours"})

      {conn, _user} = create_and_login_user(conn)
      assert delete(conn, "/posts/#{post.id}").status == 404
      assert Posts.get_post(post.id)
    end

    test "logged out is redirected away", %{conn: conn} do
      post = create_post!(author(), %{body: "x"})

      conn = delete(conn, "/posts/#{post.id}")
      assert redirected_to(conn) == "/"
      assert Posts.get_post(post.id)
    end
  end
end
