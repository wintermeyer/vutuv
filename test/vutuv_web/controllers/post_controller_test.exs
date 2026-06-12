defmodule VutuvWeb.PostControllerTest do
  @moduledoc """
  The permalink page: public posts are crawlable, restricted posts noindex
  and hide from denied readers, the teaser appears only for the
  non_followers-only case, and the deny list never leaks to readers.
  """
  use VutuvWeb.ConnCase

  import Vutuv.PostsHelpers

  alias Vutuv.Posts

  @other_login_attrs %{
    "emails" => %{"0" => %{"value" => "other@example.com"}},
    "first_name" => "other"
  }

  defp fresh_conn do
    Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})
  end

  defp pad(int), do: String.pad_leading(Integer.to_string(int), 2, "0")

  describe "GET the permalink" do
    test "renders a public post to anonymous visitors, indexable", %{conn: conn} do
      user = insert_activated_user()
      post = create_post!(user, %{body: "Hello **world**", tags: "elixir"})

      conn = get(conn, Posts.path(post))

      assert html_response(conn, 200) =~ "<strong>world</strong>"
      assert conn.resp_body =~ "elixir"
      assert get_resp_header(conn, "x-robots-tag") == []
    end

    test "redirects non-canonical URLs to the canonical form", %{conn: conn} do
      user = insert_activated_user()
      post = create_post!(user, %{body: "x"})

      # The permalink is the post id under the author archive.
      assert Posts.path(post) == "/#{user.active_slug}/posts/#{post.id}"

      # An uppercase UUID still resolves and 302s to the canonical
      # (lowercase) form.
      shouty = "/#{user.active_slug}/posts/#{String.upcase(post.id)}"
      assert redirected_to(get(conn, shouty)) == Posts.path(post)
    end

    test "404s for unknown ids, garbage segments and other authors' posts", %{conn: conn} do
      user = insert_activated_user()
      other = insert_activated_user()
      post = create_post!(other, %{body: "not under this slug"})

      assert get(conn, "/#{user.active_slug}/posts/#{Vutuv.UUIDv7.generate()}").status == 404
      assert get(conn, "/#{user.active_slug}/posts/not-a-uuid-or-year").status == 404
      # A post resolves only under its author's slug.
      assert get(conn, "/#{user.active_slug}/posts/#{post.id}").status == 404
    end

    # The member's AI choice covers their posts: the permalink page and its
    # agent-format siblings both carry the noai directives and the matching
    # Content-Signal, while staying searchable.
    test "an AI-opted-out author's post serves with the noai directives", %{conn: conn} do
      user = insert_activated_user(noai?: true)
      post = create_post!(user, %{body: "human readers welcome"})

      conn = get(conn, Posts.path(post))
      assert html_response(conn, 200) =~ "human readers welcome"
      assert get_resp_header(conn, "x-robots-tag") == ["noai, noimageai"]

      doc = get(fresh_conn(), Posts.path(post) <> ".md")
      assert doc.status == 200
      assert get_resp_header(doc, "content-signal") == ["ai-train=no, search=yes, ai-input=no"]
      assert get_resp_header(doc, "x-robots-tag") == ["noai, noimageai"]
    end

    test "restricted post: 404 for denied readers, 200 + noindex for permitted", %{conn: conn} do
      user = insert_activated_user()
      post = create_post!(user, %{body: "members only", denials: [%{"wildcard" => "logged_out"}]})

      assert get(conn, Posts.path(post)).status == 404

      {member_conn, _member} = create_and_login_user(conn)
      conn = get(member_conn, Posts.path(post))

      assert html_response(conn, 200) =~ "members only"
      # A page-level restriction covers both axes: out of search results
      # and out of AI corpora, whatever the author's own settings say.
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, noai, noimageai"]
    end

    test "followers-only post: teaser for non-followers, post for followers", %{conn: conn} do
      user = insert_activated_user()

      post =
        create_post!(user, %{
          body: "for my people",
          denials: [%{"wildcard" => "non_followers"}]
        })

      # Anonymous: teaser with a login affordance.
      teaser = get(conn, Posts.path(post))
      assert html_response(teaser, 200) =~ "followers of"
      refute teaser.resp_body =~ "for my people"

      # Logged-in non-follower: teaser with a follow button (a POST to the
      # follow route).
      {visitor_conn, _visitor} = create_and_login_user(fresh_conn())
      teaser = get(visitor_conn, Posts.path(post))
      assert html_response(teaser, 200) =~ "followers of"
      assert teaser.resp_body =~ "/follows"
      refute teaser.resp_body =~ "for my people"

      # Follower: the actual post.
      {follower_conn, follower} = create_and_login_user(fresh_conn(), @other_login_attrs)
      insert(:follow, follower: follower, followee: user)
      shown = get(follower_conn, Posts.path(post))
      assert html_response(shown, 200) =~ "for my people"
    end

    test "every other denial shape is a plain 404, never a teaser", %{conn: conn} do
      user = insert_activated_user()
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

  describe "the author's ⋯ menu on the post card" do
    test "the author sees Edit and Delete on the permalink and in the archive" do
      {author_conn, author} = create_and_login_user(fresh_conn())
      post = create_post!(author, %{body: "my words"})

      # The archive renders timeline entries, so its card ids carry the
      # entry id; the permalink shows the bare post.
      for {path, menu_id} <- [
            {Posts.path(post), "post-menu-#{post.id}"},
            {"/#{author.active_slug}/posts", "post-menu-post-#{post.id}"}
          ] do
        html = html_response(get(author_conn, path), 200)

        assert html =~ ~s(id="#{menu_id}")
        assert html =~ ~s(href="/posts/#{post.id}/edit")
        assert html =~ ~s(data-method="delete")
        assert html =~ "Delete this post permanently?"
      end
    end

    test "the permalink shows the action bar with counters to anonymous readers", %{conn: conn} do
      user = insert_activated_user()
      post = create_post!(user, %{body: "counted"})
      for fan <- [insert(:user), insert(:user)], do: :ok = Posts.like_post(fan, post)
      :ok = Posts.repost_post(insert(:user), post)

      html = html_response(get(conn, Posts.path(post)), 200)

      assert html =~ ~s(id="post-actions-#{post.id}-like")
      assert html =~ ~r/data-count="like">\s*2\s*</
      assert html =~ ~r/data-count="repost">\s*1\s*</
    end

    test "the archive lists the author's reposts with the reposted-by line", %{conn: conn} do
      reposter = insert_activated_user(first_name: "Renate", last_name: "Repost")
      original = create_post!(insert_activated_user(), %{body: "originally elsewhere"})
      :ok = Posts.repost_post(reposter, original)

      html = html_response(get(conn, "/#{reposter.active_slug}/posts"), 200)

      assert html =~ "originally elsewhere"
      assert html =~ "Reposted by Renate Repost"
    end

    test "anonymous visitors and other readers get no author menu", %{conn: conn} do
      user = insert_activated_user()
      post = create_post!(user, %{body: "public words"})

      # Anonymous: neither the author menu nor the report menu.
      anonymous = get(conn, Posts.path(post))
      refute html_response(anonymous, 200) =~ "post-menu-#{post.id}"
      refute anonymous.resp_body =~ "post-report-#{post.id}"

      # A logged-in reader gets the quiet report menu, but no Edit/Delete.
      {reader_conn, _reader} = create_and_login_user(fresh_conn(), @other_login_attrs)
      reader_view = get(reader_conn, Posts.path(post))
      refute html_response(reader_view, 200) =~ "post-menu-#{post.id}"
      assert reader_view.resp_body =~ "post-report-#{post.id}"
      assert reader_view.resp_body =~ "/reports/new?"
    end
  end

  describe "GET /:slug/posts (the author archive)" do
    test "lists the author's posts, visibility-filtered per viewer", %{conn: conn} do
      user = insert_activated_user()
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
      user = insert_activated_user()
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
      user = insert_activated_user()
      {:ok, post} = Posts.create_post(user, %{body: "crumbed"})
      date = post.published_on

      conn =
        get(conn, "/#{user.active_slug}/posts/#{date.year}/#{pad(date.month)}/#{pad(date.day)}")

      assert conn.resp_body =~ "All posts"
      assert conn.resp_body =~ ~s(href="/#{user.active_slug}/posts")
      assert conn.resp_body =~ ~s(href="/#{user.active_slug}/posts/#{date.year}")

      assert conn.resp_body =~
               ~s(href="/#{user.active_slug}/posts/#{date.year}/#{pad(date.month)}")
    end

    test "404s for nonsense period segments", %{conn: conn} do
      user = insert_activated_user()

      assert get(conn, "/#{user.active_slug}/posts/abcd").status == 404
      assert get(conn, "/#{user.active_slug}/posts/2026/13").status == 404
      assert get(conn, "/#{user.active_slug}/posts/2026/02/30").status == 404
    end
  end

  describe "the profile's View all link" do
    test "appears only when more posts exist than the profile shows", %{conn: conn} do
      user = insert_activated_user()
      for n <- 1..3, do: {:ok, _} = Posts.create_post(user, %{body: "post #{n}"})

      # The exact archive href (closing quote included): permalinks also
      # start with /posts/ but continue with the post id.
      archive_href = ~s(href="/#{user.active_slug}/posts")

      conn_without = get(conn, "/#{user.active_slug}")
      refute conn_without.resp_body =~ archive_href

      {:ok, _} = Posts.create_post(user, %{body: "post 4"})
      conn_with = get(conn, "/#{user.active_slug}")
      assert conn_with.resp_body =~ archive_href
      assert conn_with.resp_body =~ "View all"
    end
  end

  describe "the reply banner and thread" do
    test "a reply's page shows the banner with the @handle, linking the parent", %{conn: conn} do
      parent_author = insert_activated_user(first_name: "Petra", last_name: "Parent")
      parent = create_post!(parent_author, %{body: "original question"})
      {:ok, reply} = Posts.create_reply(insert_activated_user(), parent, %{body: "an answer"})

      html = conn |> get(Posts.path(reply)) |> html_response(200)

      # The banner names the account handle, not the clear name.
      assert html =~ "Replying to @#{parent_author.active_slug}"
      refute html =~ "Replying to Petra Parent"
      assert html =~ Posts.path(parent)
    end

    test "after parent deletion the banner names the author's @handle and profile", %{conn: conn} do
      parent_author = insert_activated_user(first_name: "Petra", last_name: "Parent")
      parent = create_post!(parent_author, %{body: "soon gone"})
      {:ok, reply} = Posts.create_reply(insert_activated_user(), parent, %{body: "still here"})

      {:ok, _} = Posts.delete_post(parent)

      html = conn |> get(Posts.path(reply)) |> html_response(200)

      assert html =~ "Reply to a now-deleted post by @#{parent_author.active_slug}"
      refute html =~ "by Petra Parent"
      assert html =~ ~s(href="/#{parent_author.active_slug}")
    end

    test "after the parent author's account deletion the banner is nameless", %{conn: conn} do
      parent_author = insert_activated_user(first_name: "Petra", last_name: "Parent")
      parent = create_post!(parent_author, %{body: "soon gone"})
      {:ok, reply} = Posts.create_reply(insert_activated_user(), parent, %{body: "still here"})

      # The real account-deletion path: the cascade removes the post too.
      Vutuv.Repo.delete!(parent_author)

      html = conn |> get(Posts.path(reply)) |> html_response(200)

      assert html =~ "Reply to a deleted post"
      refute html =~ "Petra Parent"
    end

    test "the parent's page lists visible replies oldest first", %{conn: conn} do
      parent = create_post!(insert_activated_user(), %{body: "the root post"})
      replier = insert_activated_user()

      {:ok, _old} = Posts.create_reply(replier, parent, %{body: "older answer"})

      {:ok, _hidden} =
        Posts.create_reply(insert_activated_user(), parent, %{
          body: "secret answer",
          denials: [%{"wildcard" => "everyone"}]
        })

      {:ok, _new} = Posts.create_reply(replier, parent, %{body: "newer answer"})

      html = conn |> get(Posts.path(parent)) |> html_response(200)

      assert html =~ "older answer"
      assert html =~ "newer answer"
      refute html =~ "secret answer"

      {i_old, _} = :binary.match(html, "older answer")
      {i_new, _} = :binary.match(html, "newer answer")
      assert i_old < i_new
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
      other = insert_activated_user()
      post = create_post!(other, %{body: "not yours"})

      {conn, _user} = create_and_login_user(conn)
      assert delete(conn, "/posts/#{post.id}").status == 404
      assert Posts.get_post(post.id)
    end

    test "logged out is redirected away", %{conn: conn} do
      post = create_post!(insert_activated_user(), %{body: "x"})

      conn = delete(conn, "/posts/#{post.id}")
      assert redirected_to(conn) == "/"
      assert Posts.get_post(post.id)
    end
  end
end
