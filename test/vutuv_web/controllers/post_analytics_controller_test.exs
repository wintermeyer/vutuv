defmodule VutuvWeb.PostAnalyticsControllerTest do
  use VutuvWeb.ConnCase

  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Posts.PostLike
  alias Vutuv.Repo
  alias Vutuv.Tags.SourceServer

  test "the author sees the reach analysis through the post menu", %{conn: conn} do
    {conn, author} = create_and_login_user(conn)

    post =
      author
      |> create_post!(%{body: "An interesting post"})
      |> Ecto.Changeset.change(
        inserted_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -86_400, :second)
      )
      |> Repo.update!()

    reader = insert_activated_user()
    Repo.insert!(%PostLike{post_id: post.id, user_id: reader.id})

    Repo.insert!(%Vutuv.Fediverse.Reaction{
      post_id: post.id,
      actor_uri: "https://social.example/users/alice",
      kind: "like",
      received_at: DateTime.utc_now(:second)
    })

    Repo.insert!(%Vutuv.Fediverse.Reaction{
      post_id: post.id,
      actor_uri: "https://boost.example/users/bob",
      handle: "bob",
      kind: "announce",
      received_at: DateTime.utc_now(:second)
    })

    Repo.insert!(%RemoteAccount{
      actor_uri: "https://boost.example/users/bob",
      host: "boost.example",
      handle: "bob",
      inbox_uri: "https://boost.example/users/bob/inbox",
      follower_count: 10_000,
      follower_count_checked_at: ~U[2026-09-15 12:00:00Z]
    })

    Repo.insert!(%SourceServer{
      host: "social.example",
      active_month: 12_345,
      status: "ok",
      checked_at: ~U[2026-09-15 12:00:00Z]
    })

    assert get(conn, "/#{author.username}/posts/#{post.id}").resp_body =~
             "Reach analysis (Beta)"

    analytics = get(conn, "/posts/#{post.id}/analytics")
    body = html_response(analytics, 200)
    assert body =~ "Reach analysis"

    assert body =~
             "A complete analysis is impossible in the Fediverse because vutuv cannot access every server and its data."

    assert body =~ "People with visible interactions"

    assert body =~
             "We cannot reliably know how many people saw this post in the Fediverse. We can only count people who visibly interacted with it"

    assert body =~ "Server network"
    assert body =~ "Momentum over time"
    assert body =~ "data-chart-tick"
    assert body =~ "data-chart-bucket-label"
    assert body |> String.split("data-chart-tick") |> length() > 3
    assert body =~ "Repost hops between servers are not visible to vutuv."
    assert body =~ "data-network-sequence"
    assert body =~ "data-network-interactions"
    assert body =~ "First visible reaction"
    assert body =~ "data-community-size-ring"
    assert body =~ "12K monthly active accounts"
    assert body =~ "NodeInfo 15 Sep 2026, 12:00 UTC"
    assert body =~ "Potential reach from reposts"
    assert body =~ "10K"
    assert body =~ ~r/10K.*text-brand-500.*>\+</s
    assert body =~ "data-repost-reach-bar"
    assert body =~ "Follower totals are fetched in the background"
    refute body =~ "Distribution signal"
    refute body =~ "This post broke out"
    refute body =~ "No visible response yet"
    assert body =~ ~r/<strong[^>]*>lower bound<\/strong>/
    assert body =~ "not a view count."
    refute body =~ "At least 1 people reacted and therefore saw the post."
    refute body =~ "Passive views and unreported activity are not counted."
    refute body =~ "What vutuv can reliably reconstruct"
    refute body =~ "The real readership is almost certainly much higher"

    assert body =~ ~s(/posts/#{post.id}/analytics/og.png)
  end

  test "a public post's analysis is public without a login", %{conn: conn} do
    author = insert_activated_user()
    post = create_post!(author, %{body: "Public statistics"})

    analytics = get(conn, "/posts/#{post.id}/analytics")

    assert html_response(analytics, 200) =~ "Reach analysis"
    assert get_resp_header(analytics, "cache-control") == ["public, max-age=60"]
  end

  test "another member sees the reach analysis in a public post's menu", %{conn: conn} do
    author = insert_activated_user()
    post = create_post!(author, %{body: "Public menu"})
    {conn, _reader} = create_and_login_user(conn)

    assert get(conn, "/#{author.username}/posts/#{post.id}").resp_body =~
             "Reach analysis (Beta)"
  end

  test "another member cannot read a restricted post's analysis", %{conn: conn} do
    author = insert_activated_user()

    post =
      create_post!(author, %{
        body: "Private statistics",
        denials: [%{wildcard: "logged_out"}]
      })

    {conn, _other} = create_and_login_user(conn)

    assert get(conn, "/posts/#{post.id}/analytics").status == 404
  end

  test "the author retains private access to a restricted post's analysis", %{conn: conn} do
    {conn, author} = create_and_login_user(conn)

    post =
      create_post!(author, %{
        body: "Private statistics",
        denials: [%{wildcard: "logged_out"}]
      })

    analytics = get(conn, "/posts/#{post.id}/analytics")

    assert html_response(analytics, 200) =~ "Reach analysis"
    assert get_resp_header(analytics, "cache-control") == ["private, no-store"]
    assert get_resp_header(analytics, "x-robots-tag") == ["noindex, nofollow"]
  end

  test "a restricted analysis stays hidden from signed-out readers", %{conn: conn} do
    post =
      create_post!(insert_activated_user(), %{
        body: "Only the author can analyze this",
        denials: [%{wildcard: "logged_out"}]
      })

    assert get(conn, "/posts/#{post.id}/analytics").status == 404
  end
end
