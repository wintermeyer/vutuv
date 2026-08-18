defmodule VutuvWeb.MastodonApi.ApiVersionSixTest do
  @moduledoc """
  What `api_versions: %{mastodon: 6}` promises a client, checked against what
  the adapter actually answers.

  Mastodon's API version is a feature-detection number, not a label: a client
  reads it out of `/api/v2/instance` and then calls the endpoints that number
  stands for. Each bump names one change (`lib/mastodon/version.rb` in
  mastodon/mastodon): 3 is `attribution_domains`, **4 the media-deletion
  methods**, 5 the `blur` filter action and **6 the hashtag feature/unfeature
  API** — with 1 and 2 carrying grouped notifications and their move to
  `/api/v2`. Claiming 6 while a client's call for one of them falls through to
  the adapter's 404 is a broken server, not a missing feature.

  Beside those, the entity fields vutuv has data for and used to send empty.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.MastodonApi
  alias Vutuv.Posts
  alias Vutuv.RateLimiter
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Tags

  describe "the status entity carries what a post really holds" do
    test "tags, mentions, language and the edit mark", %{conn: conn} do
      author = insert(:activated_user)
      # `unique_username/1` because the mention grammar is `[A-Za-z0-9_]+` and the
      # factory's default usernames carry a hyphen, which would truncate the
      # handle and fail the existence check rather than this endpoint.
      mentioned = insert(:activated_user, username: unique_username("mentioned"))
      tag_name = unique_tag_name("Elixir")

      {:ok, post} =
        Posts.create_post(author, %{
          body: "Hallo @#{mentioned.username}",
          tags: tag_name,
          language: "de"
        })

      token = mastodon_token(author, ["read"])

      status =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/statuses/#{post.id}")
        |> json_response(200)

      # A client linkifies and offers "open hashtag" from this list; it was
      # always empty, so a post's own tags were unreachable from a phone.
      assert [%{"name" => slug, "url" => url}] = status["tags"]
      assert slug == Tags.get_canonical_tag_by_slug(slug).slug
      assert url =~ "/tags/" <> slug

      # The prefill a client builds a reply from.
      assert [%{"acct" => acct, "id" => id}] = status["mentions"]
      assert acct == mentioned.username
      assert id == mentioned.id

      # Declared by the author (v7.313.0), and a client filters its timeline on
      # it — an undeclared post is treated as "every language", which is not the
      # same claim.
      assert status["language"] == "de"

      # Untouched since it was written.
      assert status["edited_at"] == nil
    end

    test "an edited post says when", %{conn: conn} do
      author = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{body: "Erste Fassung"})

      # The website's own rule: `updated_at` more than a minute past
      # `inserted_at` is what its card calls edited.
      edited_at = NaiveDateTime.add(post.inserted_at, 600)
      post = post |> Ecto.Changeset.change(updated_at: edited_at) |> Repo.update!()

      token = mastodon_token(author, ["read"])

      status =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/statuses/#{post.id}")
        |> json_response(200)

      assert status["edited_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end
  end

  describe "the account entity carries the member's proven webpages" do
    test "a verified link becomes a Mastodon field with verified_at", %{conn: conn} do
      user = insert(:activated_user)

      insert(:url,
        user: user,
        value: "https://example.org/me",
        description: "Meine Seite",
        verified_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      )

      # Unproven links stay out: `verified_at: nil` in a client reads as a plain
      # row, which is not what a proof-backed field says.
      insert(:url, user: user, value: "https://unproven.example/", description: "Noch offen")

      token = mastodon_token(user, ["read"])

      account =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/accounts/verify_credentials")
        |> json_response(200)

      assert [field] = account["fields"]
      assert field["name"] == "Meine Seite"
      assert field["value"] =~ "https://example.org/me"
      assert field["value"] =~ ~s(rel="me)
      assert field["verified_at"]
    end
  end

  describe "GET /api/v1/accounts/lookup" do
    test "resolves a bare handle and a fully qualified local one", %{conn: conn} do
      user = insert(:activated_user)
      other = insert(:activated_user)
      token = mastodon_token(user, ["read"])

      found =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/accounts/lookup", %{"acct" => other.username})
        |> json_response(200)

      assert found["id"] == other.id

      qualified =
        build_conn()
        |> mastodon_conn(token)
        |> get("/api/v1/accounts/lookup", %{
          "acct" => "@#{other.username}@#{MastodonApi.local_domain()}"
        })
        |> json_response(200)

      assert qualified["id"] == other.id
    end

    test "an unknown handle is a 404 and not the website's HTML", %{conn: conn} do
      token = mastodon_token(insert(:activated_user), ["read"])

      assert conn
             |> mastodon_conn(token)
             |> get("/api/v1/accounts/lookup", %{"acct" => "nobody-here-at-all"})
             |> json_response(404)
    end

    # The account rule, not the search page's: `GET /api/v1/accounts/:id`
    # answers an owner their own page while it is still frozen, and a lookup
    # that refused the same page for the same viewer would have a client show
    # "no such account" for a page its member manages.
    test "an owner finds their own frozen page", %{conn: conn} do
      owner = insert(:activated_user)

      page =
        insert(:organization,
          created_by_user_id: owner.id,
          frozen_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
        )

      found =
        conn
        |> mastodon_conn(mastodon_token(owner, ["read"]))
        |> get("/api/v1/accounts/lookup", %{"acct" => page.slug})
        |> json_response(200)

      assert found["id"] == page.id
    end
  end

  # `resolve/2` may reach out over WebFinger, and `Fediverse.resolve_remote_account/2`
  # claims one of the member's 30 hourly remote-follow slots BEFORE the network
  # hop. Search calls it on every query, so an address-shaped query that the
  # member did not mark as a handle must not spend one.
  describe "search resolves a foreign address only when it is written as a handle" do
    test "a bare user@host query spends no remote-follow slot", %{conn: conn} do
      user = insert(:activated_user)
      token = mastodon_token(user, ["read"])
      before = RateLimiter.peek({:fediverse_remote_follow, user.id}, :timer.hours(1))

      conn
      |> mastodon_conn(token)
      |> get("/api/v2/search", %{"q" => "alice@remote-host.invalid", "type" => "accounts"})
      |> json_response(200)

      assert RateLimiter.peek({:fediverse_remote_follow, user.id}, :timer.hours(1)) == before
    end
  end

  describe "hashtags (API version 6 territory)" do
    setup do
      user = insert(:activated_user)
      tag = insert(:tag)
      %{user: user, tag: tag, token: mastodon_token(user, ["read", "write"])}
    end

    test "GET /api/v1/tags/:id names the topic", %{conn: conn, tag: tag, token: token} do
      rendered =
        conn |> mastodon_conn(token) |> get("/api/v1/tags/#{tag.slug}") |> json_response(200)

      assert rendered["name"] == tag.slug
      assert rendered["url"] =~ "/tags/#{tag.slug}"
      refute rendered["following"]
    end

    test "follow and unfollow round-trip through vutuv's own subscription", %{
      conn: conn,
      user: user,
      tag: tag,
      token: token
    } do
      followed =
        conn
        |> mastodon_conn(token)
        |> post("/api/v1/tags/#{tag.slug}/follow")
        |> json_response(200)

      # The answer has to already say so, or the client flips its button back on
      # the next read.
      assert followed["following"]
      assert Tags.tag_followed?(user, tag)

      listed =
        build_conn()
        |> mastodon_conn(token)
        |> get("/api/v1/followed_tags")
        |> json_response(200)

      assert [%{"name" => name, "following" => true}] = listed
      assert name == tag.slug

      dropped =
        build_conn()
        |> mastodon_conn(token)
        |> post("/api/v1/tags/#{tag.slug}/unfollow")
        |> json_response(200)

      refute dropped["following"]
      refute Tags.tag_followed?(Repo.reload!(user), tag)
    end

    test "an unknown hashtag is a 404", %{conn: conn, token: token} do
      assert conn
             |> mastodon_conn(token)
             |> get("/api/v1/tags/no_such_topic_here")
             |> json_response(404)
    end

    # A client hands the hashtag back as the member typed it, and vutuv's slugs
    # are lower case. `/api/v1/timelines/tag/:hashtag` has always downcased, so
    # without this the two halves of one gesture disagreed: the timeline for
    # `#Elixir` opened and the Follow button beside it 404ed.
    test "the hashtag is matched as typed, in any casing", %{
      conn: conn,
      user: user,
      tag: tag,
      token: token
    } do
      shouted = String.upcase(tag.slug)

      rendered =
        conn |> mastodon_conn(token) |> get("/api/v1/tags/#{shouted}") |> json_response(200)

      assert rendered["name"] == tag.slug

      followed =
        build_conn()
        |> mastodon_conn(token)
        |> post("/api/v1/tags/#{shouted}/follow")
        |> json_response(200)

      assert followed["following"]
      assert Tags.tag_followed?(user, tag)
    end

    # `read` is the parent scope, and `Scopes.granted?/2` widens upward only —
    # so a token carrying the granular scopes every other route here asks for
    # was refused by this one, and a client could follow a topic it was not
    # allowed to read.
    test "a token with granular scopes may read a topic", %{conn: conn, tag: tag} do
      granular = mastodon_token(insert(:activated_user), ["read:follows", "write:follows"])

      assert conn
             |> mastodon_conn(granular)
             |> get("/api/v1/tags/#{tag.slug}")
             |> json_response(200)
    end

    # Every other list in this adapter is a page with a `Link` header; this one
    # answered the whole subscription list at once, so a member following
    # several hundred topics got one unbounded body.
    test "the followed list is a page and names the next one", %{conn: conn, user: user} do
      for _ <- 1..3, do: {:ok, _follow} = Tags.follow_tag(user, insert(:tag))

      paged =
        conn
        |> mastodon_conn(mastodon_token(user, ["read"]))
        |> get("/api/v1/followed_tags", %{"limit" => "2"})

      assert [_first, _second] = json_response(paged, 200)
      assert [link] = get_resp_header(paged, "link")
      assert link =~ ~s(rel="next")
    end
  end

  describe "grouped notifications (API version 1/2)" do
    test "a group key opens, fills and dismisses", %{conn: conn} do
      author = insert(:activated_user)
      liker = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{body: "Etwas zum Mögen"})
      :ok = Posts.like_post(liker, post)

      token = mastodon_token(author, ["read", "write"])

      %{"notification_groups" => [group]} =
        conn |> mastodon_conn(token) |> get("/api/v2/notifications") |> json_response(200)

      key = group["group_key"]

      one =
        build_conn()
        |> mastodon_conn(token)
        |> get("/api/v2/notifications/#{key}")
        |> json_response(200)

      assert one["group_key"] == key
      assert one["notifications_count"] == 1

      accounts =
        build_conn()
        |> mastodon_conn(token)
        |> get("/api/v2/notifications/#{key}/accounts")
        |> json_response(200)

      assert [%{"id" => id}] = accounts
      assert id == liker.id

      assert build_conn()
             |> mastodon_conn(token)
             |> post("/api/v2/notifications/#{key}/dismiss")
             |> json_response(200)
    end

    test "an unknown group key is a 404", %{conn: conn} do
      token = mastodon_token(insert(:activated_user), ["read"])

      assert conn
             |> mastodon_conn(token)
             |> get("/api/v2/notifications/favourite-does-not-exist")
             |> json_response(404)
    end
  end

  describe "the search page's hashtags know the viewer" do
    test "a followed tag reports following: true", %{conn: conn} do
      user = insert(:activated_user)
      other = insert(:activated_user)
      {:ok, _follow} = Social.follow(user, other.id)
      tag = insert(:tag)
      {:ok, _} = Tags.follow_tag(user, tag)

      token = mastodon_token(user, ["read"])

      %{"hashtags" => hashtags} =
        conn
        |> mastodon_conn(token)
        |> get("/api/v2/search", %{"q" => tag.name, "type" => "hashtags"})
        |> json_response(200)

      assert Enum.any?(hashtags, &(&1["name"] == tag.slug and &1["following"]))
    end
  end
end
