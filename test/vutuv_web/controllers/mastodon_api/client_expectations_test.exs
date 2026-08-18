defmodule VutuvWeb.MastodonApi.ClientExpectationsTest do
  @moduledoc """
  Shapes a Mastodon client parses without asking, and the endpoints it calls
  because this adapter says it is compatible with 4.4.

  Every case here was reported from a real client (Ivory, Ice Cubes) as a
  feature that "does not work", and every one of them was the server answering
  something a client cannot use rather than a missing feature.
  """
  use VutuvWeb.ConnCase

  import Vutuv.MastodonHelpers

  alias Vutuv.Posts
  alias Vutuv.Repo

  describe "times are stamped the way a client parses them" do
    # Mastodon always sends `2019-11-26T22:37:36.000Z`, and Apple's
    # `ISO8601DateFormatter` with `.withFractionalSeconds` — what these clients
    # build once and reuse — FAILS on a string without the milliseconds. A
    # client that cannot parse a date falls back to "now", which is why every
    # post in the timeline showed the same relative time, starting at the moment
    # the account was added to the app.
    @iso8601_ms ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/

    setup do
      author = insert(:activated_user)
      post = insert(:post, user: author)
      viewer = insert(:activated_user)

      {:ok, token: mastodon_token(viewer, ["read"]), post: post, author: author, viewer: viewer}
    end

    test "a status and its account", %{conn: conn, token: token, post: post} do
      status =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/statuses/#{post.id}")
        |> json_response(200)

      assert status["created_at"] =~ @iso8601_ms
      assert status["account"]["created_at"] =~ @iso8601_ms
    end

    test "and a notification, which used to keep its own copy of the conversion",
         %{conn: conn, post: post, author: author, viewer: viewer} do
      :ok = Posts.like_post(viewer, post)
      token = mastodon_token(author, ["read"])

      [notification | _] =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/notifications")
        |> json_response(200)

      assert notification["created_at"] =~ @iso8601_ms
    end
  end

  describe "pinned=true asks for the pinned post" do
    setup do
      member = insert(:activated_user)
      post = insert(:post, user: member)

      {:ok, token: mastodon_token(member, ["read"]), member: member, post: post}
    end

    test "nothing pinned is an empty list, not the newest post", %{
      conn: conn,
      token: token,
      member: member
    } do
      # The parameter was ignored, so a client asking for the pinned row got the
      # whole timeline and showed its newest entry as pinned — a member's only
      # post looked pinned although they had never pinned anything.
      assert conn
             |> mastodon_conn(token)
             |> get("/api/v1/accounts/#{member.id}/statuses", %{"pinned" => "true"})
             |> json_response(200) == []
    end

    test "a pinned post is the one that comes back", %{
      conn: conn,
      token: token,
      member: member,
      post: post
    } do
      {:ok, _pinned} = Posts.pin_to_profile(member, post)

      ids =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/accounts/#{member.id}/statuses", %{"pinned" => "true"})
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert ids == [post.id]
    end

    test "without the parameter the timeline is untouched", %{
      conn: conn,
      token: token,
      member: member,
      post: post
    } do
      ids =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/accounts/#{member.id}/statuses")
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert post.id in ids
    end
  end

  describe "the tabs a 4.4-compatible client expects to exist" do
    setup do
      {:ok, token: mastodon_token(insert(:activated_user), ["read"])}
    end

    test "trends, news and announcements answer an empty list, not an error", %{
      conn: conn,
      token: token
    } do
      # Mastodon answers these empty when an instance has them switched off.
      # The difference between "off" and "not implemented" is the difference
      # between an empty tab and Ice Cubes' "an error occurred, please try
      # again" — which is what its Trending and News tabs showed.
      for path <- [
            "/api/v1/trends/statuses",
            "/api/v1/trends/tags",
            "/api/v1/trends/links",
            "/api/v1/announcements",
            "/api/v1/suggestions",
            "/api/v2/suggestions"
          ] do
        assert conn |> mastodon_conn(token) |> get(path) |> json_response(200) == [],
               "expected #{path} to answer an empty list"
      end
    end
  end

  describe "grouped notifications" do
    setup do
      author = insert(:activated_user)
      post = insert(:post, user: author)
      liker = insert(:activated_user)
      :ok = Posts.like_post(liker, post)

      {:ok, token: mastodon_token(author, ["read"]), post: post, liker: liker}
    end

    test "answer the 4.3+ shape a client asks for at /api/v2/notifications", %{
      conn: conn,
      token: token,
      post: post,
      liker: liker
    } do
      # We advertise compatibility with 4.4, and a client reads that version to
      # decide which of the two endpoints to call. Ice Cubes does, so its whole
      # notifications tab errored against a server whose v1 list was fine.
      body =
        conn
        |> mastodon_conn(token)
        |> get("/api/v2/notifications")
        |> json_response(200)

      assert [group] = body["notification_groups"]
      assert group["type"] == "favourite"
      assert group["status_id"] == post.id
      assert group["notifications_count"] == 1
      assert liker.id in group["sample_account_ids"]

      # The accounts and statuses are hoisted into the two shared lists a client
      # resolves the ids against.
      assert Enum.map(body["accounts"], & &1["id"]) == [liker.id]
      assert Enum.map(body["statuses"], & &1["id"]) == [post.id]
    end

    test "gather over the whole page, not over a consecutive run", %{
      conn: conn,
      token: token,
      post: post,
      liker: liker
    } do
      # `Enum.chunk_by/2` reads like grouping and only collapses neighbours, so
      # anything timed between two likes on one post split them into two groups
      # carrying the identical `group_key` — which is the string a client keys
      # its list by. Reverting `notification_groups/1` to `chunk_by` turns this
      # red; the single-notification case above stays green either way.
      author = Repo.get!(Vutuv.Accounts.User, post.user_id)
      follower = insert(:activated_user)
      second_liker = insert(:activated_user)

      {:ok, _} = Vutuv.Social.follow(follower, author.id)
      :ok = Posts.like_post(second_liker, post)

      # Second-granularity stamps make the order of one test run a coin toss,
      # so the follow is put between the two likes on purpose.
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      stamp("post_likes", :user_id, liker.id, NaiveDateTime.add(now, -120))
      stamp("follows", :follower_id, follower.id, NaiveDateTime.add(now, -60))
      stamp("post_likes", :user_id, second_liker.id, now)

      groups =
        conn
        |> mastodon_conn(token)
        |> get("/api/v2/notifications")
        |> json_response(200)
        |> Map.fetch!("notification_groups")

      keys = Enum.map(groups, & &1["group_key"])
      assert keys == Enum.uniq(keys), "a group_key appeared twice: #{inspect(keys)}"

      assert [favourites] = Enum.filter(groups, &(&1["type"] == "favourite"))
      assert favourites["notifications_count"] == 2
      assert favourites["status_id"] == post.id
      assert liker.id in favourites["sample_account_ids"]
      assert second_liker.id in favourites["sample_account_ids"]

      # Newest first, which is the order of the page it was gathered from.
      assert Enum.map(groups, & &1["type"]) == ["favourite", "follow"]
    end

    defp stamp(table, column, id, at) do
      Repo.update_all(
        Ecto.Query.from(r in table,
          where: field(r, ^column) == type(^id, Vutuv.UUIDv7)
        ),
        set: [inserted_at: at]
      )
    end
  end

  describe "an edit vutuv refuses" do
    test "says which rule closed it, not that the status is invalid", %{conn: conn} do
      author = insert(:activated_user)
      post = insert(:post, user: author)
      :ok = Posts.like_post(insert(:activated_user), post)
      token = mastodon_token(author, ["write"])

      body =
        conn
        |> mastodon_conn(token)
        |> put("/api/v1/statuses/#{post.id}", %{"status" => "edited"})
        |> json_response(422)

      # Mastodon allows this edit and vutuv does not, so the answer has to name
      # the rule — a member reading "The status is invalid" looks for a mistake
      # in their own text.
      assert body["error"] =~ "liked"
      refute body["error"] =~ "The status is invalid"
    end
  end
end
