defmodule VutuvWeb.MastodonApi.StatusParentTest do
  @moduledoc """
  A status a Mastodon client reads must carry `in_reply_to_id` so the client can
  thread the reply under the post it answers (issue #1622). The website shows
  the parent on all four shapes below; before this the API said `null` on the
  three that cross a network boundary, so a reply looked like a standalone post.

  The rule: name the parent only when it is a status the same client could fetch
  — a local post id, or a `remote-<id>` we hold. A parent we hold no row for
  stays `null`, because an id no client can resolve is worse than none.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Posts.PostRemoteReply
  alias Vutuv.Social

  defp show(conn, token, id) do
    conn
    |> mastodon_conn(token)
    |> get("/api/v1/statuses/#{id}")
    |> json_response(200)
  end

  # A vutuv post answering a followed account's post out there — the sidecar
  # `Posts.create_remote_post_reply/3` writes, built by hand because going
  # through it claims the shared outbound budget and this file stays async
  # (`thread_parents_test.exs` is the sync one that drives the real call).
  defp answer_to_cached_post(author, account, remote_post) do
    {:ok, post} = Posts.create_post(author, %{body: "Meine Antwort nach drüben"})

    Repo.insert!(%PostRemoteReply{
      post_id: post.id,
      remote_post_id: remote_post.id,
      in_reply_to_uri: remote_post.object_uri,
      actor_uri: account.actor_uri,
      inbox_uri: account.inbox_uri,
      handle: account.handle <> "@social.example"
    })

    post
  end

  defp follow_remote(reader, account, state) do
    Repo.insert!(%Follow{
      user_id: reader.id,
      remote_account_id: account.id,
      state: state,
      follow_activity_id: "https://vutuv.test/#{reader.id}/actor#f/#{account.id}"
    })
  end

  test "a cached remote reply names the member's post it answers", %{conn: conn} do
    member = insert(:activated_user)
    {:ok, parent} = Posts.create_post(member, %{body: "Womit die Frage begann"})
    note = insert(:note, post: parent)

    token = mastodon_token(insert(:activated_user), ["read"])
    status = show(conn, token, "remote-note-" <> note.id)

    assert status["in_reply_to_id"] == parent.id
    assert status["in_reply_to_account_id"] == member.id
  end

  test "a followed account's self-reply names its cached parent, same account",
       %{conn: conn} do
    account = remote_account(handle: "alice")
    parent = cached_post(account)
    reply = cached_post(account, in_reply_to_uri: parent.object_uri)

    token = mastodon_token(insert(:activated_user), ["read"])
    status = show(conn, token, "remote-" <> reply.id)

    assert status["in_reply_to_id"] == "remote-" <> parent.id
    assert status["in_reply_to_account_id"] == "remote-" <> account.id
  end

  test "a cached reply whose parent we never held stays orphaned", %{conn: conn} do
    account = remote_account(handle: "bob")
    reply = cached_post(account, in_reply_to_uri: "https://social.example/p/never-held")

    token = mastodon_token(insert(:activated_user), ["read"])
    status = show(conn, token, "remote-" <> reply.id)

    assert status["in_reply_to_id"] == nil
    assert status["in_reply_to_account_id"] == nil
  end

  # `own_thread?/2`'s rule, which this reads the same way: a cached post names
  # its parent only inside its **own** account's thread. Somebody else's post at
  # that address is a conversation we hold one arbitrary side of, and we cache
  # it because a member follows its author, not because we followed the thread.
  test "a cached reply does not reach across accounts for its parent", %{conn: conn} do
    stranger = remote_account(handle: "greta")
    parent = cached_post(stranger)

    author = remote_account(handle: "hugo")
    reply = cached_post(author, in_reply_to_uri: parent.object_uri)

    token = mastodon_token(insert(:activated_user), ["read"])
    status = show(conn, token, "remote-" <> reply.id)

    assert status["in_reply_to_id"] == nil
  end

  test "a vutuv answer to a followed account's post names the cached post", %{conn: conn} do
    author = insert(:activated_user)
    account = remote_account(handle: "carol")
    remote_post = cached_post(account)
    follow_remote(author, account, "accepted")
    post = answer_to_cached_post(author, account, remote_post)

    token = mastodon_token(insert(:activated_user), ["read"])
    status = show(conn, token, post.id)

    assert status["in_reply_to_id"] == "remote-" <> remote_post.id
    assert status["in_reply_to_account_id"] == "remote-" <> account.id
  end

  # The same answer on a list, not only on the single status a client asks for
  # by id: the three border-crossing shapes are read off preloads and batches
  # that `statuses/2` fills for a whole page, and a timeline is where a client
  # actually threads a conversation.
  test "the home timeline names the same parent the single status does", %{conn: conn} do
    reader = insert(:activated_user)
    author = insert(:activated_user)
    {:ok, _} = Social.follow(reader, author.id)

    account = remote_account(handle: "frida")
    remote_post = cached_post(account)
    post = answer_to_cached_post(author, account, remote_post)
    follow_remote(reader, account, "accepted")

    token = mastodon_token(reader, ["read"])

    # The timeline carries the cached post itself too, since the reader follows
    # that account — the answer is the entry to read here.
    statuses =
      conn
      |> mastodon_conn(token)
      |> get("/api/v1/timelines/home")
      |> json_response(200)

    status = Enum.find(statuses, &(&1["id"] == post.id))

    assert status["in_reply_to_id"] == "remote-" <> remote_post.id
    assert status["in_reply_to_account_id"] == "remote-" <> account.id
  end

  # The gate, calibrated against the un-fixed code: take `scope_visible/2` out
  # of `Posts.note_parent_posts/2` and the first assertion goes green while the
  # second still 404s — which is the contradiction the rule above forbids. A
  # stranger's reply is usually public and says nothing about the post it
  # answers, whose author can have narrowed it since.
  test "a cached reply does not name a local parent the reader may not read", %{conn: conn} do
    member = insert(:activated_user)

    {:ok, parent} =
      Posts.create_post(member, %{
        body: "Nur für Follower",
        denials: [%{wildcard: "non_followers"}]
      })

    note = insert(:note, post: parent)
    token = mastodon_token(insert(:activated_user), ["read"])
    status = show(conn, token, "remote-note-" <> note.id)

    assert status["in_reply_to_id"] == nil
    assert status["in_reply_to_account_id"] == nil

    assert conn
           |> mastodon_conn(token)
           |> get("/api/v1/statuses/#{parent.id}")
           |> response(404)
  end

  # A page reading the same status. `Posts.scope_visible/2` knew only `nil` and
  # `%User{}`, so a page identity raised `FunctionClauseError` — a 500 on a
  # plain read. It is not a member, so it sees what an anonymous reader sees.
  test "a page reading a cached reply gets an answer, not a crash", %{conn: conn} do
    member = insert(:activated_user)
    organization = insert(:organization)
    {:ok, _} = Organizations.add_role(organization, member, "publisher", member)
    {:ok, parent} = Posts.create_post(member, %{body: "Womit die Frage begann"})
    note = insert(:note, post: parent)

    token = mastodon_token(member, ["read"], organization)
    status = show(conn, token, "remote-note-" <> note.id)

    assert status["in_reply_to_id"] == parent.id
  end

  test "a followers-only cached parent stays unnamed for a reader who does not follow",
       %{conn: conn} do
    account = remote_account(handle: "dora")
    parent = cached_post(account, audience: "followers")
    reply = cached_post(account, in_reply_to_uri: parent.object_uri)

    token = mastodon_token(insert(:activated_user), ["read"])
    status = show(conn, token, "remote-" <> reply.id)

    assert status["in_reply_to_id"] == nil
    assert status["in_reply_to_account_id"] == nil
  end

  # A follow that has been asked for but not granted reads nothing yet — both
  # `Fediverse.remote_post_readable?/2` and `Statuses.visible?/2` want
  # `state: "accepted"` — so naming the parent here hands the client an id its
  # very next request is refused for.
  test "a follow still pending does not open a followers-only parent", %{conn: conn} do
    reader = insert(:activated_user)
    account = remote_account(handle: "emil")
    parent = cached_post(account, audience: "followers")
    reply = cached_post(account, in_reply_to_uri: parent.object_uri)

    follow_remote(reader, account, "pending")

    token = mastodon_token(reader, ["read"])
    status = show(conn, token, "remote-" <> reply.id)

    assert status["in_reply_to_id"] == nil

    assert conn
           |> mastodon_conn(token)
           |> get("/api/v1/statuses/remote-#{parent.id}")
           |> response(404)
  end
end
