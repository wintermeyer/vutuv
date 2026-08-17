defmodule VutuvWeb.MastodonApi.EngagementTest do
  @moduledoc """
  What a client puts under a status and in a profile header: the three counts,
  the reader's own like / bookmark / reshare, and who the post is for.

  Every one of these was a constant before — `0`, `false`, `"public"`, `""` —
  which is worse than missing, because a client believes it. The heart stayed
  empty on a post the member had just liked, so tapping it *removed* the like;
  and a narrowed post was announced as public, so the client offered to boost
  it. Both were 200s with plausible bodies.

  Calibrated against the un-fixed presenter: drop the engagement merge and
  every assertion here fails.

  `async: false` because it drives the rate-limited API endpoints.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Posts
  alias Vutuv.Social

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  describe "a status the reader has already engaged with" do
    setup %{conn: conn} do
      author = insert(:activated_user)
      reader = insert(:activated_user, headline: "Schreibt über Elixir")
      {:ok, post} = Posts.create_post(author, %{body: "Der Beitrag"})

      :ok = Posts.like_post(reader, post)
      :ok = Posts.bookmark_post(reader, post)

      {:ok,
       conn: mastodon_conn(conn, mastodon_token(reader, ["read"])), post: post, reader: reader}
    end

    test "says so, instead of offering the reader an action they already took", %{
      conn: conn,
      post: post
    } do
      status = conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200)

      assert status["favourites_count"] == 1
      assert status["favourited"] == true
      assert status["bookmarked"] == true
      assert status["reblogged"] == false
    end

    test "carries the same figures inside a timeline, not only on the permalink", %{
      conn: conn,
      post: post
    } do
      [status] =
        conn
        |> get("/api/v1/timelines/public")
        |> json_response(200)
        |> Enum.filter(&(&1["id"] == post.id))

      assert status["favourites_count"] == 1
      assert status["favourited"] == true
    end

    test "counts replies", %{conn: conn, post: post, reader: reader} do
      {:ok, _reply} = Posts.create_reply(reader, post, %{body: "Eine Antwort"})

      status = conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200)

      assert status["replies_count"] == 1
    end
  end

  describe "visibility" do
    test "a post that carries a denial is not announced as public", %{conn: conn} do
      author = insert(:activated_user)
      reader = insert(:activated_user)

      {:ok, open} = Posts.create_post(author, %{body: "Für alle"})

      {:ok, narrowed} =
        Posts.create_post(author, %{
          body: "Nur für Folgende",
          denials: [%{"wildcard" => "non_followers"}]
        })

      {:ok, _} = Social.follow(reader, author.id)
      token = mastodon_token(reader, ["read"])

      assert visibility_of(conn, token, open) == "public"
      assert visibility_of(build_conn(), token, narrowed) == "private"
    end

    defp visibility_of(conn, token, post) do
      conn
      |> mastodon_conn(token)
      |> get("/api/v1/statuses/#{post.id}")
      |> json_response(200)
      |> Map.fetch!("visibility")
    end
  end

  describe "an account" do
    test "carries the member's own bio and their real figures", %{conn: conn} do
      user = insert(:activated_user, headline: "Baut Dinge mit Elixir")
      follower = insert(:activated_user)
      {:ok, _} = Social.follow(follower, user.id)
      {:ok, _} = Posts.create_post(user, %{body: "Ein Beitrag"})

      account =
        conn
        |> mastodon_conn(mastodon_token(user, ["read"]))
        |> get("/api/v1/accounts/verify_credentials")
        |> json_response(200)

      assert account["note"] == "<p>Baut Dinge mit Elixir</p>"
      assert account["followers_count"] == 1
      assert account["statuses_count"] == 1
    end

    test "escapes the bio rather than passing markup through", %{conn: conn} do
      user = insert(:activated_user, headline: ~s|<script>alert("x")</script>|)

      account =
        conn
        |> mastodon_conn(mastodon_token(user, ["read"]))
        |> get("/api/v1/accounts/verify_credentials")
        |> json_response(200)

      refute account["note"] =~ "<script>"
      assert account["note"] =~ "&lt;script&gt;"
    end
  end
end
