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
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias Vutuv.Posts.PostRemoteReply

  defp show(conn, token, id) do
    conn
    |> mastodon_conn(token)
    |> get("/api/v1/statuses/#{id}")
    |> json_response(200)
  end

  defp remote_account(handle) do
    actor = "https://social.example/users/#{handle}"

    Repo.insert!(%RemoteAccount{
      actor_uri: actor,
      host: "social.example",
      handle: handle,
      name: String.capitalize(handle),
      inbox_uri: actor <> "/inbox"
    })
  end

  defp cached_post(account, overrides \\ %{}) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      struct(
        %RemotePost{
          remote_account_id: account.id,
          object_uri: "https://social.example/p/#{System.unique_integer([:positive])}",
          origin_url: "https://social.example/@them/1",
          content_text: "Ein Gedanke von drüben.",
          audience: "public",
          kind: "note",
          published_at: now,
          received_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        overrides
      )
    )
  end

  test "a local reply names its local parent", %{conn: conn} do
    author = insert(:activated_user)
    {:ok, parent} = Posts.create_post(author, %{body: "Die Ausgangsfrage"})
    {:ok, reply} = Posts.create_reply(author, parent, %{body: "Die Antwort"})

    token = mastodon_token(insert(:activated_user), ["read"])
    status = show(conn, token, reply.id)

    assert status["in_reply_to_id"] == parent.id
    assert status["in_reply_to_account_id"] == author.id
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
    account = remote_account("alice")
    parent = cached_post(account)
    reply = cached_post(account, %{in_reply_to_uri: parent.object_uri})

    token = mastodon_token(insert(:activated_user), ["read"])
    status = show(conn, token, "remote-" <> reply.id)

    assert status["in_reply_to_id"] == "remote-" <> parent.id
    assert status["in_reply_to_account_id"] == "remote-" <> account.id
  end

  test "a cached reply whose parent we never held stays orphaned", %{conn: conn} do
    account = remote_account("bob")
    reply = cached_post(account, %{in_reply_to_uri: "https://social.example/p/never-held"})

    token = mastodon_token(insert(:activated_user), ["read"])
    status = show(conn, token, "remote-" <> reply.id)

    assert status["in_reply_to_id"] == nil
    assert status["in_reply_to_account_id"] == nil
  end

  test "a vutuv answer to a followed account's post names the cached post", %{conn: conn} do
    author = insert(:activated_user)
    account = remote_account("carol")
    remote_post = cached_post(account)

    Repo.insert!(%Follow{
      user_id: author.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{author.id}/actor#f/#{account.id}"
    })

    {:ok, post} = Posts.create_post(author, %{body: "Meine Antwort nach drüben"})

    Repo.insert!(%PostRemoteReply{
      post_id: post.id,
      remote_post_id: remote_post.id,
      in_reply_to_uri: remote_post.object_uri,
      actor_uri: account.actor_uri,
      inbox_uri: account.inbox_uri,
      handle: "carol@social.example"
    })

    token = mastodon_token(insert(:activated_user), ["read"])
    status = show(conn, token, post.id)

    assert status["in_reply_to_id"] == "remote-" <> remote_post.id
    assert status["in_reply_to_account_id"] == "remote-" <> account.id
  end
end
