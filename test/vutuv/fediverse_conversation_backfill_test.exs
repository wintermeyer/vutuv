defmodule Vutuv.FediverseConversationBackfillTest do
  @moduledoc """
  The data migration that gives already-stored private messages a conversation.

  A migration's row-touching branches are dead code against a fresh test
  database — it migrates an empty schema, so every insert in it "passes"
  without ever running. This drives it directly, against rows that look like
  the ones production holds, which is the only way the backfill is covered at
  all.

  `async: false`: it runs the migration module against the shared tables.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Chat
  alias Vutuv.Chat.Conversation
  alias Vutuv.Chat.Message
  alias Vutuv.Fediverse.PrivateMessage
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Repo.Migrations.BackfillFediverseConversations

  # Migrations live outside the compiled app, so the module has to be loaded
  # before it can be driven — and only when it is not already, which it is
  # when `mix test`'s own `ecto.migrate` ran in this VM.
  unless Code.ensure_loaded?(BackfillFediverseConversations) do
    Code.require_file("priv/repo/migrations/20260920074019_backfill_fediverse_conversations.exs")
  end

  @actor "https://social.example/users/mia"

  test "an old exchange becomes one conversation, in order, linked both ways" do
    user = insert(:activated_user, fediverse_followers?: true, fediverse_replies?: true)
    post = create_post!(user, %{body: "Mein Beitrag"})

    note =
      insert(:note,
        post: post,
        audience: "direct",
        actor_uri: @actor,
        inbox_uri: @actor <> "/inbox",
        handle: "mia",
        display_name: "Mia Scholz",
        content_text: "Frage lieber privat.",
        received_at: DateTime.add(DateTime.utc_now(:second), -3600)
      )

    sent =
      Repo.insert!(%PrivateMessage{
        user_id: user.id,
        post_id: post.id,
        body: "Klar, gern.",
        object_uri: "https://vutuv.example/#{user.username}/actor/private-messages/1",
        in_reply_to_uri: note.object_uri,
        recipient_actor_uri: @actor
      })

    BackfillFediverseConversations.run(Repo)

    assert [%Conversation{} = conversation] = Repo.all(Conversation)
    assert conversation.user_a_id == user.id
    # Nobody had an account row for Mia yet, so the backfill minted one from
    # what the note recorded.
    account = Repo.get!(RemoteAccount, conversation.remote_account_id)
    assert account.actor_uri == @actor
    assert account.handle == "mia"
    assert account.host == "social.example"

    # She wrote first, so the member is the recipient — and the member
    # answered, so it is not sitting in the request list.
    assert is_nil(conversation.initiator_id)
    assert conversation.status == "accepted"

    messages = Repo.all(from(m in Message, order_by: m.inserted_at))
    assert [incoming, outgoing] = messages
    assert incoming.body == "Frage lieber privat."
    assert incoming.note_id == note.id
    assert incoming.sender_remote_account_id == account.id
    assert outgoing.body == "Klar, gern."
    assert outgoing.private_message_id == sent.id
    assert outgoing.sender_id == user.id

    assert conversation.last_message_at

    # And the member's own list shows it.
    assert [entry] = Chat.list_conversations(user)
    assert entry.conversation.id == conversation.id
    assert %RemoteAccount{} = entry.other
  end

  test "running it twice changes nothing" do
    user = insert(:activated_user, fediverse_followers?: true, fediverse_replies?: true)
    post = create_post!(user, %{body: "Mein Beitrag"})

    insert(:note,
      post: post,
      audience: "direct",
      actor_uri: @actor,
      inbox_uri: @actor <> "/inbox",
      content_text: "Hallo."
    )

    BackfillFediverseConversations.run(Repo)
    BackfillFediverseConversations.run(Repo)

    assert Repo.aggregate(Conversation, :count) == 1
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(RemoteAccount, :count) == 1
  end

  test "a public note is left alone" do
    user = insert(:activated_user, fediverse_followers?: true, fediverse_replies?: true)
    post = create_post!(user, %{body: "Mein Beitrag"})
    insert(:note, post: post, audience: "public", actor_uri: @actor)

    BackfillFediverseConversations.run(Repo)

    assert Repo.aggregate(Conversation, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
  end
end
