defmodule Vutuv.FediversePrivateRepliesTest do
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.PrivateMessage
  alias Vutuv.Posts
  alias VutuvWeb.Fediverse.Docs

  setup do
    Vutuv.RateLimiter.reset()
    user = insert(:activated_user, fediverse_followers?: true, fediverse_replies?: true)
    post = create_post!(user, %{body: "Public root"})

    note =
      insert(:note,
        post: post,
        audience: "direct",
        actor_uri: "https://social.example/users/alice",
        inbox_uri: "https://social.example/users/alice/inbox"
      )

    {:ok, user: user, post: post, note: note}
  end

  test "the storage supports a message without a post or parent", %{user: user, note: note} do
    message = %PrivateMessage{
      user_id: user.id,
      recipient_actor_uri: note.actor_uri,
      object_uri: "https://vutuv.example/private-messages/#{Vutuv.UUIDv7.generate()}"
    }

    assert {:ok, saved} =
             message
             |> PrivateMessage.changeset(%{body: "A new conversation"})
             |> Repo.insert()

    saved = Repo.reload!(saved)
    assert is_nil(saved.post_id)
    assert is_nil(saved.in_reply_to_uri)
    assert saved.recipient_actor_uri == note.actor_uri
  end

  test "stores text separately and queues only to the sender", %{
    user: user,
    post: post,
    note: note
  } do
    {:ok, _} =
      Fediverse.add_follower(user, %{
        actor_uri: "https://follower.example/u",
        inbox_uri: "https://follower.example/inbox"
      })

    count = Repo.aggregate(Posts.Post, :count)
    assert {:ok, reply} = Fediverse.create_private_reply(user, note, %{body: "<b>Only Alice</b>"})
    assert reply.post_id == post.id
    assert reply.in_reply_to_uri == note.object_uri
    assert reply.recipient_actor_uri == note.actor_uri
    assert Fediverse.get_actor(user)
    assert Repo.aggregate(Posts.Post, :count) == count
    assert [saved] = Fediverse.list_private_replies(user, note)
    assert saved.id == reply.id
    delivery = Repo.get_by!(Delivery, user_id: user.id)
    assert delivery.inbox_uri == note.inbox_uri
    activity = Jason.decode!(delivery.activity_json)
    assert activity["to"] == [note.actor_uri]
    assert activity["cc"] == []
    assert activity["object"]["to"] == [note.actor_uri]
    assert activity["object"]["cc"] == []
    assert activity["object"]["inReplyTo"] == note.object_uri
    assert activity["object"]["content"] == "&lt;b&gt;Only Alice&lt;/b&gt;"
    refute Map.has_key?(activity["object"], "attachment")
  end

  test "delivers a signed private Create to the recipient", %{user: user, note: note} do
    parent = self()

    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          parent,
          {:delivered, conn.request_path, Map.new(conn.req_headers), Jason.decode!(body)}
        )

        Plug.Conn.send_resp(conn, 202, "")
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
    {:ok, reply} = Fediverse.create_private_reply(user, note, %{body: "Just for you"})
    assert Fediverse.deliver_due() == 1
    assert_receive {:delivered, "/users/alice/inbox", headers, activity}
    assert headers["signature"] =~ Docs.key_id(user)
    assert activity["object"]["id"] == reply.object_uri
    assert activity["to"] == [note.actor_uri]
    assert [] = Repo.all(Delivery)
  end

  test "rejects strangers, stale targets, public notes and invalid text", %{
    user: user,
    note: note
  } do
    stranger = insert(:activated_user, fediverse_followers?: true)
    assert {:error, :not_visible} = Fediverse.create_private_reply(stranger, note, %{body: "No"})
    assert [] = Fediverse.list_private_replies(stranger, note)

    assert {:error, %Ecto.Changeset{}} =
             Fediverse.create_private_reply(user, note, %{body: "   "})

    assert {:error, %Ecto.Changeset{}} =
             Fediverse.create_private_reply(user, note, %{body: String.duplicate("a", 5001)})

    Repo.update!(Ecto.Changeset.change(note, audience: "public"))
    assert {:error, :note_not_private} = Fediverse.create_private_reply(user, note, %{body: "No"})
    Repo.delete!(note)
    assert {:error, :not_visible} = Fediverse.create_private_reply(user, note, %{body: "No"})
    assert [] = Repo.all(PrivateMessage)
    assert [] = Repo.all(Delivery)
  end

  test "rechecks federation and delivery coordinates", %{user: user, note: note} do
    Repo.update!(Ecto.Changeset.change(user, fediverse_followers?: false))
    assert {:error, :not_federating} = Fediverse.create_private_reply(user, note, %{body: "No"})
    Repo.update!(Ecto.Changeset.change(Repo.reload!(user), fediverse_followers?: true))
    Repo.update!(Ecto.Changeset.change(note, inbox_uri: "https://other.example/inbox"))
    assert {:error, :no_inbox} = Fediverse.create_private_reply(user, note, %{body: "No"})
    assert [] = Repo.all(PrivateMessage)
    assert [] = Repo.all(Delivery)
  end

  test "applies the outbound rate limit", %{user: user, note: note} do
    old = Application.get_env(:vutuv, :fediverse_outbound_reply_limit)
    Application.put_env(:vutuv, :fediverse_outbound_reply_limit, 1)

    on_exit(fn ->
      if old,
        do: Application.put_env(:vutuv, :fediverse_outbound_reply_limit, old),
        else: Application.delete_env(:vutuv, :fediverse_outbound_reply_limit)
    end)

    assert {:ok, _} = Fediverse.create_private_reply(user, note, %{body: "One"})
    assert {:error, :reply_capped} = Fediverse.create_private_reply(user, note, %{body: "Two"})
    assert Repo.aggregate(PrivateMessage, :count) == 1
  end

  test "accepts follow-up only from the recipient and keeps it private", %{
    user: user,
    post: post,
    note: note
  } do
    {:ok, reply} = Fediverse.create_private_reply(user, note, %{body: "Private answer"})
    actor = %{uri: note.actor_uri, inbox: note.inbox_uri, handle: "alice", name: "Alice"}

    activity = %{
      "type" => "Create",
      "to" => [Docs.actor_url(user)],
      "object" => %{
        "type" => "Note",
        "id" => "https://social.example/statuses/followup",
        "inReplyTo" => reply.object_uri,
        "to" => [Docs.actor_url(user)],
        "content" => "Next question"
      }
    }

    assert :skip =
             Fediverse.record_reply(user, activity, %{actor | uri: "https://evil.example/a"})

    public = put_in(activity, ["object", "to"], ["https://www.w3.org/ns/activitystreams#Public"])
    assert :skip = Fediverse.record_reply(user, public, actor)
    assert :ok = Fediverse.record_reply(user, activity, actor)
    received = Repo.get_by!(Fediverse.Note, object_uri: activity["object"]["id"])
    assert received.post_id == post.id
    refute Fediverse.Note.public?(received)
    assert {:ok, _} = Fediverse.create_private_reply(user, received, %{body: "Next answer"})
  end
end
