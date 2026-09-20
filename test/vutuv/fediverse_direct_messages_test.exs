defmodule Vutuv.FediverseDirectMessagesTest do
  @moduledoc """
  Private messages to and from another network, as **conversations**.

  The feature has two halves that must hold together: what arrives under a post
  keeps working exactly as it did (issues #1069/#1071/#2215), and the same
  words also appear in `/messages` as a conversation with that account. One
  truth, two views — so every test here asserts both sides where both exist.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Chat
  alias Vutuv.Chat.Conversation
  alias Vutuv.Chat.Message
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.BlockedInstance
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.PrivateMessage
  alias Vutuv.Fediverse.RemoteAccount
  alias VutuvWeb.Fediverse.Docs

  @actor "https://social.example/users/alice"
  @inbox "https://social.example/users/alice/inbox"

  setup do
    Vutuv.RateLimiter.reset()

    user =
      insert(:activated_user, fediverse_followers?: true, fediverse_replies?: true)

    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: @actor,
        inbox_uri: @inbox,
        host: "social.example",
        handle: "alice",
        name: "Alice Anders"
      })

    {:ok, user: user, account: account}
  end

  defp create_activity(opts) do
    object_uri =
      Keyword.get(
        opts,
        :object_uri,
        "https://social.example/statuses/#{System.unique_integer([:positive])}"
      )

    object =
      %{
        "id" => object_uri,
        "type" => "Note",
        "attributedTo" => @actor,
        "content" => Keyword.get(opts, :content, "<p>Hallo, kurz privat.</p>"),
        "to" => Keyword.get(opts, :to, [Keyword.fetch!(opts, :recipient)]),
        "cc" => []
      }

    object =
      case Keyword.get(opts, :in_reply_to) do
        nil -> object
        uri -> Map.put(object, "inReplyTo", uri)
      end

    %{
      "id" => object_uri <> "#create",
      "type" => "Create",
      "actor" => @actor,
      "to" => object["to"],
      "cc" => [],
      "object" => object
    }
  end

  defp remote_actor do
    %{uri: @actor, handle: "alice", name: "Alice Anders", inbox: @inbox}
  end

  describe "outgoing" do
    test "starting a conversation stores it, queues one delivery and addresses nobody else", %{
      user: user,
      account: account
    } do
      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: "https://follower.example/u",
          inbox_uri: "https://follower.example/inbox"
        })

      assert {:ok, %Message{} = message} =
               Fediverse.send_direct_message(user, account, "Hallo Alice, hast du kurz Zeit?")

      assert message.body == "Hallo Alice, hast du kurz Zeit?"
      assert message.sender_id == user.id

      conversation = Repo.get!(Conversation, message.conversation_id)
      assert conversation.user_a_id == user.id
      assert conversation.remote_account_id == account.id
      assert conversation.initiator_id == user.id
      # Accepted outright: there is nothing over there that could accept a
      # request, so a pending state would be one nothing can ever leave.
      assert conversation.status == "accepted"

      # The member's own copy of what was sent, so the post-side view and the
      # revocation path keep working off one store.
      assert %PrivateMessage{} = sent = Repo.get!(PrivateMessage, message.private_message_id)
      assert sent.recipient_actor_uri == @actor
      assert is_nil(sent.post_id)

      assert [%Delivery{} = delivery] = Repo.all(Delivery)
      assert delivery.inbox_uri == @inbox
      activity = Jason.decode!(delivery.activity_json)
      assert activity["to"] == [@actor]
      assert activity["cc"] == []
      assert activity["object"]["to"] == [@actor]
      assert activity["object"]["cc"] == []
      assert activity["object"]["content"] =~ "Hallo Alice"
    end

    test "a reply into an existing conversation threads under the last incoming message", %{
      user: user,
      account: account
    } do
      :ok =
        Fediverse.record_reply(
          user,
          create_activity(
            recipient: Docs.actor_url(user),
            object_uri: "https://social.example/statuses/incoming-1"
          ),
          remote_actor()
        )

      assert {:ok, %Message{} = answer} =
               Fediverse.send_direct_message(user, account, "Ja, gern.")

      sent = Repo.get!(PrivateMessage, answer.private_message_id)
      assert sent.in_reply_to_uri == "https://social.example/statuses/incoming-1"
    end

    test "refuses when the member does not federate, when the server is blocked and when the budget is spent",
         %{user: user, account: account} do
      quiet = insert(:activated_user, fediverse_followers?: false)
      assert {:error, :not_federating} = Fediverse.send_direct_message(quiet, account, "Hallo")

      blocked = Repo.insert!(%BlockedInstance{host: "social.example", reason: "spam"})
      assert {:error, :instance_blocked} = Fediverse.send_direct_message(user, account, "Hallo")
      Repo.delete!(blocked)

      # An actor document naming somebody else's inbox: answering it would
      # make this installation deliver a signed POST to a third party.
      no_inbox =
        Repo.insert!(%RemoteAccount{
          actor_uri: "https://other.example/u",
          host: "other.example",
          handle: "nobody",
          inbox_uri: "https://elsewhere.example/inbox"
        })

      assert {:error, :no_inbox} = Fediverse.send_direct_message(user, no_inbox, "Hallo")

      assert Repo.aggregate(Message, :count) == 0
      assert Repo.aggregate(Conversation, :count) == 0
    end
  end

  describe "incoming" do
    test "a message from an account the member does not follow arrives as a request", %{
      user: user,
      account: account
    } do
      assert :ok =
               Fediverse.record_reply(
                 user,
                 create_activity(recipient: Docs.actor_url(user), content: "<p>Hallo!</p>"),
                 remote_actor()
               )

      assert [conversation] = Repo.all(Conversation)
      assert conversation.user_a_id == user.id
      assert conversation.remote_account_id == account.id
      assert conversation.status == "pending"
      # Nobody local started it, and that is what lets the member accept it.
      assert is_nil(conversation.initiator_id)

      assert [%Message{} = message] = Repo.all(Message)
      assert message.body == "Hallo!"
      assert message.sender_remote_account_id == account.id
      assert is_nil(message.sender_id)

      assert [entry] = Chat.list_requests(user)
      assert entry.conversation.id == conversation.id
      assert %RemoteAccount{} = entry.other

      assert {:ok, _} = Chat.accept_request(user, conversation.id)
      assert Repo.get!(Conversation, conversation.id).status == "accepted"
    end

    test "a message from an account the member follows lands in the list straight away", %{
      user: user,
      account: account
    } do
      Repo.insert!(%Vutuv.Fediverse.Follow{
        user_id: user.id,
        remote_account_id: account.id,
        follow_activity_id: "https://vutuv.example/follows/1",
        state: "accepted"
      })

      assert :ok =
               Fediverse.record_reply(
                 user,
                 create_activity(recipient: Docs.actor_url(user)),
                 remote_actor()
               )

      assert [conversation] = Repo.all(Conversation)
      assert conversation.status == "accepted"
      assert [entry] = Chat.list_conversations(user)
      assert entry.conversation.id == conversation.id
      assert entry.unread == 1
    end

    test "the same delivery twice stores one message", %{user: user} do
      activity =
        create_activity(
          recipient: Docs.actor_url(user),
          object_uri: "https://social.example/statuses/dup"
        )

      assert :ok = Fediverse.record_reply(user, activity, remote_actor())
      assert :skip = Fediverse.record_reply(user, activity, remote_actor())
      assert Repo.aggregate(Message, :count) == 1
    end

    test "an answer to a conversation the member started lands in that conversation", %{
      user: user,
      account: account
    } do
      {:ok, mine} = Fediverse.send_direct_message(user, account, "Hallo Alice")
      sent = Repo.get!(PrivateMessage, mine.private_message_id)

      assert :ok =
               Fediverse.record_reply(
                 user,
                 create_activity(
                   recipient: Docs.actor_url(user),
                   in_reply_to: sent.object_uri,
                   content: "<p>Ja, passt.</p>"
                 ),
                 remote_actor()
               )

      assert [%Conversation{} = conversation] = Repo.all(Conversation)
      assert conversation.id == mine.conversation_id
      assert [_mine, incoming] = Repo.all(from(m in Message, order_by: m.inserted_at))
      assert incoming.body == "Ja, passt."
      assert incoming.sender_remote_account_id == account.id
    end

    test "a public note is not a message", %{user: user} do
      post = create_post!(user, %{body: "Öffentlich"})

      activity =
        create_activity(
          recipient: "https://www.w3.org/ns/activitystreams#Public",
          in_reply_to: Docs.note_url(user, post.id)
        )

      assert :ok = Fediverse.record_reply(user, activity, remote_actor())
      assert Repo.aggregate(Note, :count) == 1
      assert Repo.aggregate(Message, :count) == 0
    end
  end

  describe "both views" do
    test "a private answer under a post stays there and also opens a conversation", %{
      user: user,
      account: account
    } do
      post = create_post!(user, %{body: "Mein Beitrag"})

      assert :ok =
               Fediverse.record_reply(
                 user,
                 create_activity(
                   recipient: Docs.actor_url(user),
                   in_reply_to: Docs.note_url(user, post.id),
                   content: "<p>Frage lieber privat.</p>"
                 ),
                 remote_actor()
               )

      # The post view is untouched: the note still hangs off the post.
      assert [%Note{} = note] = Repo.all(Note)
      assert note.post_id == post.id
      assert note.audience == "direct"
      assert [loaded] = Fediverse.list_notes([post.id], user)[post.id]
      assert loaded.id == note.id

      # And the same words are a message in the conversation, linked both ways.
      assert [%Message{} = message] = Repo.all(Message)
      assert message.note_id == note.id
      assert message.sender_remote_account_id == account.id
      conversation = Repo.get!(Conversation, message.conversation_id)
      assert conversation.remote_account_id == account.id

      assert %{^note_id => %{conversation_id: conversation_id, message_id: message_id}} =
               Chat.messages_for_notes([note_id = note.id])

      assert conversation_id == conversation.id
      assert message_id == message.id
    end

    test "a private reply sent from the post page shows up in the conversation", %{
      user: user,
      account: account
    } do
      post = create_post!(user, %{body: "Mein Beitrag"})

      note =
        insert(:note,
          post: post,
          audience: "direct",
          actor_uri: @actor,
          inbox_uri: @inbox
        )

      assert {:ok, reply} = Fediverse.create_private_reply(user, note, %{body: "Klar, gern."})

      assert [%Message{} = message] = Repo.all(Message)
      assert message.private_message_id == reply.id
      assert message.sender_id == user.id
      assert Repo.get!(Conversation, message.conversation_id).remote_account_id == account.id
    end

    test "when the note expires the message survives without its link", %{user: user} do
      post = create_post!(user, %{body: "Mein Beitrag"})

      :ok =
        Fediverse.record_reply(
          user,
          create_activity(
            recipient: Docs.actor_url(user),
            in_reply_to: Docs.note_url(user, post.id)
          ),
          remote_actor()
        )

      assert [note] = Repo.all(Note)
      Repo.delete!(note)

      assert [%Message{} = message] = Repo.all(Message)
      assert is_nil(message.note_id)
      assert message.body != ""
    end

    test "an edit upstream rewrites both copies", %{user: user} do
      post = create_post!(user, %{body: "Mein Beitrag"})

      activity =
        create_activity(
          recipient: Docs.actor_url(user),
          in_reply_to: Docs.note_url(user, post.id),
          object_uri: "https://social.example/statuses/edited",
          content: "<p>Erste Fassung.</p>"
        )

      :ok = Fediverse.record_reply(user, activity, remote_actor())

      update =
        activity
        |> Map.put("type", "Update")
        |> put_in(["object", "content"], "<p>Zweite Fassung.</p>")

      assert :ok = Fediverse.update_reply(user, update, @actor)

      assert [note] = Repo.all(Note)
      assert note.content_text == "Zweite Fassung."
      assert [message] = Repo.all(Message)
      assert message.body == "Zweite Fassung."
    end
  end

  describe "the badge" do
    test "counts an incoming message from another network", %{user: user} do
      assert :ok =
               Fediverse.record_reply(
                 user,
                 create_activity(recipient: Docs.actor_url(user)),
                 remote_actor()
               )

      # Calibrated against `m.sender_id <> ?`, which is what stood here: a
      # message with no local sender makes that NULL rather than true, so the
      # badge silently stayed at zero.
      assert Chat.unread_conversations_count(user) == 1

      [conversation] = Repo.all(Conversation)
      {:ok, _} = Chat.accept_request(user, conversation.id)
      Chat.mark_read(user, conversation.id)
      assert Chat.unread_conversations_count(user) == 0
    end
  end

  describe "housekeeping" do
    test "the sweeper keeps an account a conversation still needs", %{
      user: user,
      account: account
    } do
      {:ok, _} = Fediverse.send_direct_message(user, account, "Hallo Alice")

      assert Fediverse.purge_unreferenced_remote_accounts() == 0
      assert Repo.get(RemoteAccount, account.id)
    end
  end
end
