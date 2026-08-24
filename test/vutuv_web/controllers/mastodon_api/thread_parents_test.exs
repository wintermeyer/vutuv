defmodule VutuvWeb.MastodonApi.ThreadParentsTest do
  @moduledoc """
  What a client is told a status answers, once the conversation crosses a
  network border — issues #1640 and #1641.

  Two surfaces carry that relation and a client threads from whichever it has:
  `in_reply_to_id` on the single status, and `ancestors` in its `/context`. For
  a cached *reply* both are asserted here and they name the same thing. For a
  cached *post* only `/context` names it: filling `in_reply_to_id` there is
  issue #1622, in flight as a separate change, so this file pins the half that
  is done rather than pretending both are.

  Calibrated against the un-fixed adapter: drop the answered-object lookup out
  of `Vutuv.MastodonApi.Presenter` or out of
  `VutuvWeb.MastodonApi.StatusController` and the matching test here goes red.

  `async: false` because answering something on another network claims the
  shared outbound budget.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Posts
  alias Vutuv.Repo

  # Every test here reads as somebody with no relationship to anybody: the
  # relation under test is what a stranger's client is told.
  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()

    {:ok, conn: mastodon_conn(conn, mastodon_token(insert(:activated_user), ["read"]))}
  end

  describe "an answer to a cached reply from another network" do
    setup do
      author = federating_member()
      {:ok, root} = Posts.create_post(author, %{body: "Die Wurzel"})
      note = insert(:note, post: root)
      {:ok, answer} = Posts.create_remote_reply(author, note, %{"body" => "Danke, freut mich!"})

      {:ok, root: root, note: note, answer: answer}
    end

    # Issue #1641: `create_remote_reply/3` files the answer as an ordinary local
    # reply to the post the cached reply hangs under (issue #1070), so without
    # the fix `in_reply_to_id` is the root post and a client labels the answer
    # "Replying to @member" where it addresses a stranger.
    test "names the cached reply, not the post underneath it", %{
      conn: conn,
      note: note,
      answer: answer
    } do
      status = conn |> get("/api/v1/statuses/#{answer.id}") |> json_response(200)

      assert status["in_reply_to_id"] == "remote-note-" <> note.id
    end

    # The id it names has to be one this client can fetch, or the "Replying to"
    # line leads to an error screen.
    test "and that id resolves to the reply itself", %{conn: conn, answer: answer} do
      named =
        conn
        |> get("/api/v1/statuses/#{answer.id}")
        |> json_response(200)
        |> Map.fetch!("in_reply_to_id")

      parent =
        conn |> recycle_mastodon() |> get("/api/v1/statuses/#{named}") |> json_response(200)

      assert parent["content"] =~ "Guter Punkt"
    end

    # The account named beside it is the one the reply's own status carries, so
    # a client that already holds the reply matches the two up.
    test "and names the stranger's account rather than the member's", %{
      conn: conn,
      note: note,
      answer: answer
    } do
      answer_status = conn |> get("/api/v1/statuses/#{answer.id}") |> json_response(200)

      note_status =
        conn
        |> recycle_mastodon()
        |> get("/api/v1/statuses/remote-note-#{note.id}")
        |> json_response(200)

      assert answer_status["in_reply_to_account_id"] == note_status["account"]["id"]
    end

    # Issue #1640: the two surfaces agree. The cached reply sits between the
    # root post and the answer, oldest first.
    test "and its context carries the cached reply above it", %{
      conn: conn,
      root: root,
      note: note,
      answer: answer
    } do
      context = conn |> get("/api/v1/statuses/#{answer.id}/context") |> json_response(200)

      assert Enum.map(context["ancestors"], & &1["id"]) == [root.id, "remote-note-" <> note.id]
    end

    # A reply the sender addressed to the member alone cannot be answered at all
    # (`check_remote_reply/2`), so a private note here is one an upstream
    # `Update` narrowed afterwards — and its id answers 404 to everybody but the
    # member whose post it hangs under. The local parent is the honest fallback.
    test "but a reply narrowed after the fact is not named", %{
      conn: conn,
      root: root,
      note: note,
      answer: answer
    } do
      Repo.update!(Ecto.Changeset.change(note, audience: "direct"))

      status = conn |> get("/api/v1/statuses/#{answer.id}") |> json_response(200)

      assert status["in_reply_to_id"] == root.id
    end
  end

  describe "an ordinary reply" do
    test "still names the post above it", %{conn: conn} do
      author = insert(:activated_user)
      {:ok, root} = Posts.create_post(author, %{body: "Die Wurzel"})
      {:ok, reply} = Posts.create_reply(author, root, %{body: "Die Antwort"})

      status = conn |> get("/api/v1/statuses/#{reply.id}") |> json_response(200)

      assert status["in_reply_to_id"] == root.id
    end
  end

  describe "a self-reply from another network" do
    setup do
      account = remote_account()
      parent = cached_post(account, content_text: "Erster Teil.")

      reply =
        cached_post(account, content_text: "Zweiter Teil.", in_reply_to_uri: parent.object_uri)

      {:ok, account: account, parent: parent, reply: reply}
    end

    # Issue #1640: without the fix `/context` answered the empty conversation
    # for anything from another network, so a followed account's self-reply
    # stood in the client as an orphan although we serve its parent.
    test "answers the cached post above it", %{conn: conn, parent: parent, reply: reply} do
      context = conn |> get("/api/v1/statuses/remote-#{reply.id}/context") |> json_response(200)

      assert Enum.map(context["ancestors"], & &1["id"]) == ["remote-" <> parent.id]
      assert context["descendants"] == []
    end

    test "walks the whole chain, oldest first", %{
      conn: conn,
      account: account,
      parent: parent,
      reply: reply
    } do
      third =
        cached_post(account, content_text: "Dritter Teil.", in_reply_to_uri: reply.object_uri)

      context = conn |> get("/api/v1/statuses/remote-#{third.id}/context") |> json_response(200)

      assert Enum.map(context["ancestors"], & &1["id"]) ==
               ["remote-" <> parent.id, "remote-" <> reply.id]
    end

    # Holding the parent is not the same as being allowed to read it: an account
    # can narrow a single post to its followers, and this reader follows nobody.
    test "but stops at a parent the reader may not see", %{
      conn: conn,
      parent: parent,
      reply: reply
    } do
      Repo.update!(Ecto.Changeset.change(parent, audience: "followers"))

      context = conn |> get("/api/v1/statuses/remote-#{reply.id}/context") |> json_response(200)

      assert context == %{"ancestors" => [], "descendants" => []}
    end

    # A thread of a different account is not this account's thread — the column
    # is scoped, so a stranger cannot graft their post above somebody else's.
    test "and never borrows a post from another account", %{conn: conn, account: account} do
      stranger = cached_post(remote_account(), content_text: "Fremd.")
      reply = cached_post(account, content_text: "Antwort.", in_reply_to_uri: stranger.object_uri)

      context = conn |> get("/api/v1/statuses/remote-#{reply.id}/context") |> json_response(200)

      assert context["ancestors"] == []
    end

    # Two cached posts naming each other is broken data from somebody else's
    # server, and the walk must end rather than pad the chain with the loop.
    test "and a chain that points back at itself ends", %{conn: conn, account: account} do
      first = cached_post(account, content_text: "Eins.")
      second = cached_post(account, content_text: "Zwei.", in_reply_to_uri: first.object_uri)
      Repo.update!(Ecto.Changeset.change(first, in_reply_to_uri: second.object_uri))

      context = conn |> get("/api/v1/statuses/remote-#{second.id}/context") |> json_response(200)

      assert Enum.map(context["ancestors"], & &1["id"]) == ["remote-" <> first.id]
    end
  end

  describe "an answer written here to a cached post" do
    # Issue #1640: the answer is a top-level vutuv post (there is nothing local
    # underneath it), so without the fix its context was empty although the post
    # it addresses is one we serve.
    test "carries that cached post as its ancestor", %{conn: conn} do
      remote = cached_post(remote_account())

      {:ok, answer} =
        Posts.create_remote_post_reply(federating_member(), remote, %{
          "body" => "Sehe ich auch so."
        })

      context = conn |> get("/api/v1/statuses/#{answer.id}/context") |> json_response(200)

      assert Enum.map(context["ancestors"], & &1["id"]) == ["remote-" <> remote.id]
    end
  end
end
