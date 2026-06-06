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

  describe "GET the permalink" do
    test "renders a public post to anonymous visitors, indexable", %{conn: conn} do
      user = author()
      post = create_post!(user, %{body: "Hello **world**", tags: "elixir"})

      conn = get(conn, Posts.path(post))

      assert html_response(conn, 200) =~ "<strong>world</strong>"
      assert conn.resp_body =~ "elixir"
      assert get_resp_header(conn, "x-robots-tag") == []
    end

    test "redirects non-canonical URLs to the padded canonical", %{conn: conn} do
      user = author()
      post = create_post!(user, %{body: "x"})
      date = post.published_on

      sloppy = "/#{user.active_slug}/#{date.year}/#{date.month}/#{date.day}/#{post.seq}"
      conn = get(conn, sloppy)

      assert redirected_to(conn) == Posts.path(post)
    end

    test "404s for unknown posts and unparseable dates", %{conn: conn} do
      user = author()

      assert get(conn, "/#{user.active_slug}/2026/06/05/0001").status == 404
      assert get(conn, "/#{user.active_slug}/abcd/06/05/0001").status == 404
      assert get(conn, "/#{user.active_slug}/2026/13/05/0001").status == 404
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
