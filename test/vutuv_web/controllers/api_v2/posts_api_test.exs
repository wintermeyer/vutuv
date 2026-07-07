defmodule VutuvWeb.ApiV2.PostsApiTest do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth
  alias Vutuv.Posts

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    me = insert_activated_user()
    other = insert_activated_user()

    {:ok, token, _} = ApiAuth.create_pat(me, %{"name" => "t", "scopes" => ["posts:write"]})

    {:ok, conn: conn, me: me, other: other, token: token}
  end

  describe "create / read / update / delete" do
    test "the full lifecycle of a post", %{conn: conn, me: me, token: token} do
      conn1 =
        json_req(conn, :post, token, "/api/2.0/posts", %{
          body: "Hello **API**",
          tags: "elixir, phoenix"
        })

      created = json_response(conn1, 201)
      assert %{"id" => id, "body_markdown" => "Hello **API**"} = created
      assert Enum.sort(created["tags"]) == ["elixir", "phoenix"]

      conn2 = get(authed(build_conn(), token), "/api/2.0/posts/#{id}")
      assert json_response(conn2, 200)["id"] == id

      conn3 = json_req(build_conn(), :patch, token, "/api/2.0/posts/#{id}", %{body: "Edited"})
      assert json_response(conn3, 200)["body_markdown"] == "Edited"

      conn4 = delete(authed(build_conn(), token), "/api/2.0/posts/#{id}")
      assert conn4.status == 204
      assert Posts.get_post(me, id) == nil
    end

    test "an empty post is a 422", %{conn: conn, token: token} do
      conn = json_req(conn, :post, token, "/api/2.0/posts", %{body: ""})
      assert conn.status == 422
    end

    test "a body that embeds an image is a 422", %{conn: conn, token: token} do
      conn =
        json_req(conn, :post, token, "/api/2.0/posts", %{
          body: "hi ![x](/post_images/t/large.avif)"
        })

      assert conn.status == 422
      assert json_response(conn, 422)["errors"]["body"]
    end

    test "audience denials apply: a connections-only post hides from strangers", %{
      conn: conn,
      me: me,
      other: other,
      token: token
    } do
      conn1 =
        json_req(conn, :post, token, "/api/2.0/posts", %{
          body: "Connections only",
          denials: [%{"wildcard" => "non_connections"}]
        })

      %{"id" => id} = json_response(conn1, 201)

      {:ok, stranger_token, _} =
        ApiAuth.create_pat(other, %{"name" => "s", "scopes" => ["posts:read"]})

      conn2 = get(authed(build_conn(), stranger_token), "/api/2.0/posts/#{id}")
      assert conn2.status == 404

      connect!(me, other)
      conn3 = get(authed(build_conn(), stranger_token), "/api/2.0/posts/#{id}")
      assert conn3.status == 200
    end

    test "cannot edit someone else's post", %{conn: conn, other: other, token: token} do
      post = insert(:post, user: other)

      conn = json_req(conn, :patch, token, "/api/2.0/posts/#{post.id}", %{body: "hijack"})
      assert conn.status == 404
    end
  end

  describe "archive and feed" do
    test "the author archive lists posts with ids", %{conn: conn, other: other, token: token} do
      post = insert(:post, user: other, body: "Archived post")

      conn = get(authed(conn, token), "/api/2.0/users/#{other.username}/posts")
      body = json_response(conn, 200)

      assert body["total"] == 1
      assert [%{"id" => id}] = body["posts"]
      assert id == post.id
    end

    test "the feed shows followed authors and pages by cursor", %{
      conn: conn,
      me: me,
      other: other,
      token: token
    } do
      follow!(me, other)
      for n <- 1..3, do: insert(:post, user: other, body: "Post #{n}")

      conn1 = get(authed(conn, token), "/api/2.0/feed?limit=2")
      page1 = json_response(conn1, 200)
      assert length(page1["posts"]) == 2
      assert page1["more"] == true
      assert is_binary(page1["next_cursor"])

      conn2 =
        get(
          authed(build_conn(), token),
          "/api/2.0/feed?limit=2&cursor=#{URI.encode_www_form(page1["next_cursor"])}"
        )

      page2 = json_response(conn2, 200)
      assert length(page2["posts"]) == 1
      assert page2["more"] == false
      assert page2["next_cursor"] == nil
    end

    test "a tampered cursor is a 400", %{conn: conn, token: token} do
      conn = get(authed(conn, token), "/api/2.0/feed?cursor=garbage")
      assert conn.status == 400
    end

    test "a multiply-reposted post is one feed entry carrying the reposter roster", %{
      conn: conn,
      me: me,
      token: token
    } do
      renate = insert_activated_user(first_name: "Renate", last_name: "Repost")
      bruno = insert_activated_user(first_name: "Bruno", last_name: "Booster")
      follow!(me, renate)
      follow!(me, bruno)
      post = insert(:post, user: insert_activated_user(), body: "shared twice")
      :ok = Posts.repost_post(renate, post)
      :ok = Posts.repost_post(bruno, post)

      body = json_response(get(authed(conn, token), "/api/2.0/feed"), 200)
      entries = Enum.filter(body["posts"], &(&1["id"] == post.id))

      # One entry, not two; the roster is person refs, newest first, and
      # `reposted_by` stays the newest single ref.
      assert [entry] = entries
      assert Enum.map(entry["reposters"], & &1["name"]) == ["Bruno Booster", "Renate Repost"]
      assert entry["reposted_by"]["name"] == "Bruno Booster"
    end
  end

  describe "replies" do
    test "replying to a public post", %{conn: conn, other: other, token: token} do
      parent = insert(:post, user: other)

      conn1 =
        json_req(conn, :post, token, "/api/2.0/posts/#{parent.id}/replies", %{body: "Nice one"})

      reply = json_response(conn1, 201)
      assert reply["in_reply_to"]["url"] =~ parent.id

      conn2 = get(authed(build_conn(), token), "/api/2.0/posts/#{parent.id}")
      assert json_response(conn2, 200)["reply_count"] == 1
    end

    test "a restricted parent refuses replies with a 409", %{conn: conn, me: me, token: token} do
      {:ok, parent} =
        Posts.create_post(me, %{
          "body" => "only me",
          "denials" => [%{"wildcard" => "everyone"}]
        })

      conn = json_req(conn, :post, token, "/api/2.0/posts/#{parent.id}/replies", %{body: "reply"})
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["reason"] == "restricted"
    end
  end

  describe "engagement" do
    test "like, engagement doc, unlike", %{conn: conn, other: other, token: token} do
      post = insert(:post, user: other)

      conn1 = put(authed(conn, token), "/api/2.0/posts/#{post.id}/like")
      body = json_response(conn1, 200)
      assert body["likes"] == 1
      assert body["liked?"] == true

      conn2 = put(authed(build_conn(), token), "/api/2.0/posts/#{post.id}/like")
      assert json_response(conn2, 200)["likes"] == 1

      conn3 = delete(authed(build_conn(), token), "/api/2.0/posts/#{post.id}/like")
      assert json_response(conn3, 200)["liked?"] == false
    end

    test "reposting a restricted post is a 409", %{conn: conn, me: me, token: token} do
      {:ok, post} =
        Posts.create_post(me, %{
          "body" => "restricted",
          "denials" => [%{"wildcard" => "logged_out"}]
        })

      conn = put(authed(conn, token), "/api/2.0/posts/#{post.id}/repost")
      assert conn.status == 409
    end

    test "audience locking: a reposted post refuses restriction", %{
      conn: conn,
      me: me,
      other: other,
      token: token
    } do
      post = insert(:post, user: me)
      :ok = Posts.repost_post(other, Vutuv.Posts.get_post(post.id))

      conn =
        json_req(conn, :patch, token, "/api/2.0/posts/#{post.id}", %{
          body: post.body,
          denials: [%{"wildcard" => "non_connections"}]
        })

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["reason"] == "visibility_locked"
    end

    test "posts:read suffices for reading but not engaging", %{
      conn: conn,
      me: me,
      other: other
    } do
      {:ok, read_token, _} = ApiAuth.create_pat(me, %{"name" => "r", "scopes" => ["posts:read"]})
      post = insert(:post, user: other)

      assert get(authed(conn, read_token), "/api/2.0/posts/#{post.id}").status == 200
      assert put(authed(build_conn(), read_token), "/api/2.0/posts/#{post.id}/like").status == 403
    end
  end
end
