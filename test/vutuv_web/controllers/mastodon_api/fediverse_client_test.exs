defmodule VutuvWeb.MastodonApi.FediverseClientTest do
  @moduledoc """
  What a Mastodon client (Ivory, Ice Cubes) got back once a member's timeline
  really carried posts from other networks — the follow-up to the round of fixes
  in #1565, all of it reported from a phone.

  Four of the five failures here were **500s with an HTML body**, which a client
  that decodes every answer as JSON reports as "no posts found" or a bare error:
  one missing pair of clauses in `Vutuv.MastodonApi.Presenter` meant a bare
  `%RemotePost{}` had no rendering at all, and that record is what both the
  Federated tab and every status action on something from another network hand
  over. The fifth was quieter and worse: zeroes a client believes.

  Calibrated against the un-fixed adapter — remove `status_from_entry/1`'s struct
  clauses, the avatar and cover lookups, the reshare wrapper or the embedded
  counts, and the matching test here goes red.

  `async: false` because it drives the rate-limited API endpoints.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse.PostBoost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.MastodonApi
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Posts
  alias Vutuv.Repo

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp remote_account(attrs \\ []) do
    uri = attrs[:actor_uri] || "https://social.example/users/them#{unique()}"

    Repo.insert!(%RemoteAccount{
      actor_uri: uri,
      host: URI.parse(uri).host,
      handle: attrs[:handle] || "them",
      name: attrs[:name] || "Them",
      inbox_uri: uri <> "/inbox",
      avatar: attrs[:avatar],
      avatar_moderation: attrs[:avatar_moderation]
    })
  end

  defp cached_post(account, attrs \\ []) do
    now = DateTime.utc_now(:second)

    Repo.insert!(%RemotePost{
      remote_account_id: account.id,
      object_uri: "https://social.example/p/#{unique()}",
      content_text: attrs[:content_text] || "Von woanders.",
      audience: "public",
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
    |> Repo.preload(:remote_account)
  end

  defp unique, do: System.unique_integer([:positive])

  # A like, boost or reply leaves this site signed with the member's own key, so
  # the outbound gates refuse an account that does not federate — which is a rule,
  # not the bug under test here.
  defp federating_member do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Vutuv.Fediverse.ensure_actor(user)
    Repo.reload!(user)
  end

  describe "the Federated tab" do
    test "lists the posts this site has cached instead of failing", %{conn: conn} do
      reader = insert(:activated_user)
      post = cached_post(remote_account())

      [status] =
        conn
        |> mastodon_conn(mastodon_token(reader, ["read"]))
        |> get("/api/v1/timelines/public", %{"remote" => "true"})
        |> json_response(200)

      assert status["id"] == "remote-" <> post.id
      assert status["content"] =~ "Von woanders."
    end

    test "answers the merged public timeline with both worlds in it", %{conn: conn} do
      reader = insert(:activated_user)
      author = insert(:activated_user)
      {:ok, own} = Posts.create_post(author, %{body: "Von hier."})
      remote = cached_post(remote_account())

      ids =
        conn
        |> mastodon_conn(mastodon_token(reader, ["read"]))
        |> get("/api/v1/timelines/public")
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert own.id in ids
      assert ("remote-" <> remote.id) in ids
    end
  end

  describe "acting on a post from another network" do
    setup %{conn: conn} do
      reader = federating_member()
      post = cached_post(remote_account())

      {:ok, conn: mastodon_conn(conn, mastodon_token(reader, ["read", "write"])), post: post}
    end

    test "favouriting answers the status rather than a 500", %{conn: conn, post: post} do
      status =
        conn
        |> post("/api/v1/statuses/remote-#{post.id}/favourite")
        |> json_response(200)

      assert status["id"] == "remote-" <> post.id
      assert status["favourited"] == true
    end

    test "bookmarking answers the status too", %{conn: conn, post: post} do
      status =
        conn
        |> post("/api/v1/statuses/remote-#{post.id}/bookmark")
        |> json_response(200)

      assert status["bookmarked"] == true
    end

    test "a member who does not federate is told what to switch on", %{conn: conn} do
      reader = insert(:activated_user)
      cached = cached_post(remote_account())

      body =
        conn
        |> recycle()
        |> mastodon_conn(mastodon_token(reader, ["read", "write"]))
        |> post("/api/v1/statuses/remote-#{cached.id}/favourite")
        |> json_response(422)

      assert body["error"] =~ "Fediverse"
      refute body["error"] =~ "could not be completed"
    end

    test "the conversation is empty rather than missing", %{conn: conn, post: post} do
      context = conn |> get("/api/v1/statuses/remote-#{post.id}/context") |> json_response(200)

      assert context == %{"ancestors" => [], "descendants" => []}
    end

    # The empty answer still has to pass the same gate as every other read here:
    # a 200 to any id that merely resolves confirms the object exists, which is
    # what a followers-only cached post must not do.
    test "but only for a status the reader may see", %{conn: conn} do
      closed =
        Repo.update!(Ecto.Changeset.change(cached_post(remote_account()), audience: "followers"))

      assert conn
             |> get("/api/v1/statuses/remote-#{closed.id}/context")
             |> json_response(404)
    end

    test "and the status itself still carries the author's figures", %{conn: conn, post: post} do
      status = conn |> get("/api/v1/statuses/remote-#{post.id}") |> json_response(200)

      # A remote author has no counts of ours to state, and asking for none is
      # what keeps a single-status render free of the batch entirely.
      assert status["account"]["statuses_count"] == 0
    end
  end

  describe "an account from another network" do
    test "carries its own picture once the image gate cleared it", %{conn: _conn} do
      account = remote_account(avatar: "pic.avif", avatar_moderation: "approved")

      rendered = Presenter.account(account)

      assert rendered.avatar == MastodonApi.main_url(RemoteAccount.avatar_url(account))
      assert rendered.avatar_static == rendered.avatar
      refute rendered.avatar == Presenter.fallback_avatar()
    end

    test "keeps the stand-in while the gate has not cleared it" do
      account = remote_account(avatar: "pic.avif", avatar_moderation: "pending")

      assert Presenter.account(account).avatar == Presenter.fallback_avatar()
    end

    test "keeps the stand-in when we hold no picture at all" do
      assert Presenter.account(remote_account()).avatar == Presenter.fallback_avatar()
    end
  end

  describe "a profile header" do
    test "is the member's cover photo, not the installation's icon", %{conn: conn} do
      user = insert(:activated_user, cover_photo: "cover.avif", cover_moderation: "approved")

      account =
        conn
        |> mastodon_conn(mastodon_token(user, ["read"]))
        |> get("/api/v1/accounts/verify_credentials")
        |> json_response(200)

      assert account["header"] =~ "cover"
      assert account["header_static"] == account["header"]
      refute account["header"] == Presenter.fallback_avatar()
    end

    test "falls back to a banner rather than to the square app icon" do
      user = insert(:activated_user)
      account = Presenter.account(user)

      assert account.header == Presenter.fallback_header()
      refute account.header == Presenter.fallback_avatar()
    end

    test "is a page's cover for a page, and its logo stays the avatar" do
      page = insert(:organization, logo: "logo-token", cover: "cover-token")
      account = Presenter.account(page)

      assert account.header =~ "cover-token"
      assert account.avatar =~ "logo-token"
    end

    test "a page with no cover gets the banner, not its own missing logo" do
      account = Presenter.account(insert(:organization, logo: "logo-token", cover: nil))

      assert account.header == Presenter.fallback_header()
      assert account.avatar =~ "logo-token"
    end
  end

  describe "the account embedded in a status" do
    test "carries the same figures the profile endpoint answers", %{conn: conn} do
      author = insert(:activated_user)
      {:ok, _post} = Posts.create_post(author, %{body: "Eins"})
      {:ok, _post} = Posts.create_post(author, %{body: "Zwei"})

      conn = mastodon_conn(conn, mastodon_token(author, ["read"]))

      header = conn |> get("/api/v1/accounts/verify_credentials") |> json_response(200)

      [status | _rest] =
        conn
        |> get("/api/v1/accounts/#{author.id}/statuses")
        |> json_response(200)

      assert header["statuses_count"] == 2
      assert status["account"]["statuses_count"] == header["statuses_count"]
      assert status["account"]["followers_count"] == header["followers_count"]
    end
  end

  describe "a reshare" do
    test "is rendered as one, with the booster on the outside", %{conn: conn} do
      reader = insert(:activated_user)
      author = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{body: "Weitergereicht"})
      booster = remote_account(handle: "booster", name: "Booster")

      boost =
        Repo.insert!(%PostBoost{
          remote_account_id: booster.id,
          post_id: post.id,
          activity_id: "https://social.example/activities/#{unique()}",
          announced_at: DateTime.utc_now(:second)
        })

      entry = %{
        id: "boost-" <> boost.id,
        post: post,
        remote_post: nil,
        boosted_by: booster,
        reposted_by: nil,
        at: DateTime.to_naive(boost.announced_at)
      }

      [status] = Presenter.statuses([entry], reader)

      assert status.id == "boost-" <> boost.id
      assert status.account.acct == "booster@social.example"
      assert status.content == ""
      assert status.reblog.id == post.id
      assert status.reblog.account.id == author.id

      # And the id it hands out resolves back to the post it passed on.
      resolved =
        conn
        |> mastodon_conn(mastodon_token(reader, ["read"]))
        |> get("/api/v1/statuses/boost-#{boost.id}")
        |> json_response(200)

      assert resolved["id"] == post.id
    end

    test "a member's own reshare stays theirs on the outside", %{conn: conn} do
      author = insert(:activated_user)
      sharer = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{body: "Geteilt"})
      :ok = Posts.repost_post(sharer, post)

      [status | _rest] =
        conn
        |> mastodon_conn(mastodon_token(sharer, ["read"]))
        |> get("/api/v1/accounts/#{sharer.id}/statuses")
        |> json_response(200)

      assert String.starts_with?(status["id"], "repost-")
      assert status["account"]["id"] == sharer.id
      assert status["reblog"]["id"] == post.id
      assert status["reblog"]["account"]["id"] == author.id
    end
  end

  describe "walking an account timeline that holds a reshare" do
    # The blocker this round: a reshare is its own status now, so the id a
    # client hands back is the **reshare row's**, while the walk was bounded on
    # the post id (`Posts.author_statuses/3`). Those are different uuids, and a
    # reshare row is younger than nearly every post — so `post_id < <reshare>`
    # stayed true for the whole table and the same page came back for ever.
    test "makes progress instead of handing out the same page for ever", %{conn: conn} do
      author = insert(:activated_user)
      stranger = insert(:activated_user)

      # An old post by somebody else, reshared now: the case where the two ids
      # are furthest apart.
      {:ok, foreign} = Posts.create_post(stranger, %{body: "Fremder Beitrag"})
      {:ok, own_one} = Posts.create_post(author, %{body: "Eins"})
      :ok = Posts.repost_post(author, foreign)
      {:ok, own_two} = Posts.create_post(author, %{body: "Zwei"})

      conn = mastodon_conn(conn, mastodon_token(author, ["read"]))

      seen = walk(conn, "/api/v1/accounts/#{author.id}/statuses", nil, [], 0)

      assert length(seen) == 3
      assert length(Enum.uniq(seen)) == 3
      assert own_one.id in seen
      assert own_two.id in seen
      assert Enum.any?(seen, &String.starts_with?(&1, "repost-"))
    end

    # One row at a time, the way a client scrolls, with a hard stop so a
    # non-terminating walk fails as a wrong length rather than hanging the suite.
    defp walk(_conn, _path, _max_id, seen, rounds) when rounds > 10, do: seen

    defp walk(conn, path, max_id, seen, rounds) do
      params = if max_id, do: %{"limit" => "1", "max_id" => max_id}, else: %{"limit" => "1"}

      case conn |> recycle_token() |> get(path, params) |> json_response(200) do
        [] ->
          seen

        [status] ->
          walk(conn, path, status["id"], seen ++ [status["id"]], rounds + 1)
      end
    end

    # `Phoenix.ConnTest` reuses one conn per request; recycling keeps the bearer
    # header while clearing the previous response.
    defp recycle_token(conn) do
      [header] = Plug.Conn.get_req_header(conn, "authorization")

      conn
      |> Phoenix.ConnTest.recycle()
      |> Map.put(:host, conn.host)
      |> Plug.Conn.put_req_header("authorization", header)
    end
  end

  describe "the instance document" do
    test "names the API generation a client can check, not only the prose version", %{conn: conn} do
      instance = conn |> on_mastodon_host() |> get("/api/v2/instance") |> json_response(200)

      assert instance["api_versions"] == %{"mastodon" => 6}
      assert instance["version"] =~ "compatible; vutuv"
    end

    test "says how to reach the people who run this installation", %{conn: conn} do
      instance = conn |> on_mastodon_host() |> get("/api/v2/instance") |> json_response(200)
      {email, _handle} = MastodonApi.operator_contact()

      assert instance["contact"]["email"] == email
      assert instance["contact"]["email"] != ""
    end

    test "names the operator's own account once the handle resolves here", %{conn: conn} do
      {_email, handle} = MastodonApi.operator_contact()
      insert(:activated_user, username: handle)

      instance = conn |> on_mastodon_host() |> get("/api/v2/instance") |> json_response(200)

      assert instance["contact"]["account"]["acct"] == handle
    end

    test "answers no account rather than a dead one when nobody holds the handle", %{conn: conn} do
      instance = conn |> on_mastodon_host() |> get("/api/v2/instance") |> json_response(200)

      assert instance["contact"]["account"] == nil
    end

    test "the v1 document carries the same two facts", %{conn: conn} do
      {email, handle} = MastodonApi.operator_contact()
      insert(:activated_user, username: handle)

      instance = conn |> on_mastodon_host() |> get("/api/v1/instance") |> json_response(200)

      assert instance["email"] == email
      assert instance["contact_account"]["acct"] == handle
    end
  end
end
