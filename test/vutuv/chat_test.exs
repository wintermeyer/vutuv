defmodule Vutuv.ChatTest do
  use Vutuv.DataCase

  import Vutuv.ChatHelpers

  alias Vutuv.Chat
  alias Vutuv.Chat.{Conversation, Message, Participant}

  defp user(attrs \\ []), do: insert(:activated_user, attrs)

  # Message ordering ties at second precision; shift a message into the past so
  # order assertions stay deterministic.
  defp backdate_message!(message, seconds) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -seconds)
    Repo.update_all(from(m in Message, where: m.id == ^message.id), set: [inserted_at: at])
    %{message | inserted_at: at}
  end

  # Pin a message's inserted_at to an exact (microsecond-precise) instant.
  defp set_inserted_at!(message, %NaiveDateTime{} = at) do
    Repo.update_all(from(m in Message, where: m.id == ^message.id), set: [inserted_at: at])
    %{message | inserted_at: at}
  end

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  describe "find_or_create_conversation/2" do
    test "creates a pending conversation between strangers" do
      me = user()
      other = user()

      assert {:ok, %Conversation{} = conversation} =
               Chat.find_or_create_conversation(me, other)

      assert conversation.status == "pending"
      assert conversation.initiator_id == me.id
      assert conversation.user_a_id < conversation.user_b_id
      assert Repo.aggregate(Participant, :count) == 2
    end

    test "creates an accepted conversation when the recipient follows the sender" do
      me = user()
      other = user()
      follow!(other, me)

      assert {:ok, %Conversation{status: "accepted"}} =
               Chat.find_or_create_conversation(me, other)
    end

    test "the sender following the recipient does not unlock direct delivery" do
      me = user()
      other = user()
      follow!(me, other)

      assert {:ok, %Conversation{status: "pending"}} =
               Chat.find_or_create_conversation(me, other)
    end

    test "is idempotent and pair-normalized: both directions return the same conversation" do
      me = user()
      other = user()

      {:ok, conversation} = Chat.find_or_create_conversation(me, other)
      assert {:ok, %Conversation{id: same_id}} = Chat.find_or_create_conversation(other, me)
      assert same_id == conversation.id
      assert Repo.aggregate(Conversation, :count) == 1
      assert Repo.aggregate(Participant, :count) == 2
    end

    test "rejects messaging yourself" do
      me = user()
      assert {:error, :self} = Chat.find_or_create_conversation(me, me)
    end

    test "rejects unactivated accounts on either side" do
      activated = user()
      unactivated = insert(:user, email_confirmed?: false)

      assert {:error, :not_activated} =
               Chat.find_or_create_conversation(unactivated, activated)

      assert {:error, :not_activated} =
               Chat.find_or_create_conversation(activated, unactivated)
    end

    test "the decliner re-initiating re-opens a fresh request from them (issue #779)" do
      a = user()
      b = user()

      # A requests, sends the one request message, B declines.
      {:ok, conversation} = Chat.find_or_create_conversation(a, b)
      {:ok, _} = Chat.send_message(a, conversation.id, "let's connect")
      {:ok, %Conversation{status: "declined"}} = Chat.decline_request(b, conversation.id)

      # B (the decliner) opens A's profile and clicks Message: instead of
      # dead-ending on the hidden declined row, it re-opens as a fresh pending
      # request from B, which B can now see.
      assert {:ok, %Conversation{id: same_id, status: "pending", initiator_id: b_id}} =
               Chat.find_or_create_conversation(b, a)

      assert same_id == conversation.id
      assert b_id == b.id
      assert %Conversation{} = Chat.get_conversation(b, conversation.id)

      # The original request's message is dropped, so B gets their one request
      # message and last_message_at is cleared.
      assert Repo.aggregate(
               from(m in Message, where: m.conversation_id == ^conversation.id),
               :count
             ) == 0

      assert Repo.get!(Conversation, conversation.id).last_message_at == nil
      assert {:ok, %Message{}} = Chat.send_message(b, conversation.id, "actually, hi")
    end

    test "re-opening as the decliner counts against the request rate limit (issue #779)" do
      b = user()
      x = user()

      # X requests b; b declines, leaving a declined row b could re-open.
      {:ok, declined} = Chat.find_or_create_conversation(x, b)
      {:ok, %Conversation{status: "declined"}} = Chat.decline_request(b, declined.id)

      # b spends its own new-request budget on fresh strangers.
      for _ <- 1..Chat.new_conversation_limit() do
        assert {:ok, _} = Chat.find_or_create_conversation(b, user())
      end

      # Re-opening the declined row is a fresh request from b, so it is limited.
      assert {:error, :rate_limited} = Chat.find_or_create_conversation(b, x)
    end

    test "the original requester re-initiating still sees only their unanswered request" do
      a = user()
      b = user()

      {:ok, conversation} = Chat.find_or_create_conversation(a, b)
      {:ok, %Conversation{}} = Chat.decline_request(b, conversation.id)

      # A re-initiating returns the same row, still declined-but-shown-pending
      # and still A's: A never learns it was declined, and B is not re-requested.
      assert {:ok, %Conversation{id: same_id, status: "declined", initiator_id: a_id}} =
               Chat.find_or_create_conversation(a, b)

      assert same_id == conversation.id
      assert a_id == a.id
    end

    test "rate-limits opening new pending conversations, but not accepted ones" do
      me = user()

      for _ <- 1..Chat.new_conversation_limit() do
        assert {:ok, _} = Chat.find_or_create_conversation(me, user())
      end

      assert {:error, :rate_limited} = Chat.find_or_create_conversation(me, user())

      # Direct (accepted) conversations are not request spam and stay open.
      follower = user()
      follow!(follower, me)

      assert {:ok, %Conversation{status: "accepted"}} =
               Chat.find_or_create_conversation(me, follower)

      # Re-fetching an existing conversation is never limited either.
      assert {:ok, _} = Chat.find_or_create_conversation(me, follower)
    end
  end

  describe "cold_outreach_count/1 (the admin-visible counter, #934)" do
    test "counts new stranger requests without moving the counter" do
      me = user()
      assert Chat.cold_outreach_count(me) == 0

      {:ok, _} = Chat.find_or_create_conversation(me, user())
      {:ok, _} = Chat.find_or_create_conversation(me, user())
      assert Chat.cold_outreach_count(me) == 2

      # Peeking is read-only: reading it again does not spend the budget.
      assert Chat.cold_outreach_count(me) == 2

      # An accepted (opt-in) conversation is not cold outreach and doesn't count.
      follower = user()
      follow!(follower, me)
      {:ok, %Conversation{status: "accepted"}} = Chat.find_or_create_conversation(me, follower)
      assert Chat.cold_outreach_count(me) == 2
    end

    test "the cap defaults to a generous 20 and is config-driven" do
      assert Chat.new_conversation_limit() == 20
    end
  end

  describe "get_conversation/2" do
    test "returns the conversation for a participant, nil for outsiders" do
      [a, b, outsider] = [user(), user(), user()]
      conversation = insert_conversation_between(a, b)

      assert %Conversation{} = Chat.get_conversation(a, conversation.id)
      assert %Conversation{} = Chat.get_conversation(b, conversation.id)
      assert Chat.get_conversation(outsider, conversation.id) == nil
    end

    test "hides a declined conversation from the recipient but not the initiator" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b, status: "declined", initiator: a)

      assert %Conversation{} = Chat.get_conversation(a, conversation.id)
      assert Chat.get_conversation(b, conversation.id) == nil
    end
  end

  describe "send_message/3" do
    test "delivers into an accepted conversation and bumps last_message_at" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b)

      assert {:ok, %Message{} = message} = Chat.send_message(a, conversation.id, "  hello  ")
      assert message.body == "hello"
      assert message.sender.id == a.id
      assert Repo.get!(Conversation, conversation.id).last_message_at
    end

    test "rejects a message body that embeds an image" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Chat.send_message(a, conversation.id, "hi ![x](https://evil.example/pixel.png)")

      assert "must not contain images" in errors_on(changeset).body
    end

    test "broadcasts to the conversation topic and the recipient's activity topic" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b)

      Chat.subscribe(conversation.id)
      Vutuv.Activity.subscribe(b.id)

      message = send!(a, conversation)
      message_id = message.id
      conversation_id = conversation.id

      assert_receive {:new_message, %Message{id: ^message_id}}
      assert_receive {:new_message, %{conversation_id: ^conversation_id}}
    end

    test "does not notify the sender's own activity topic" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b)

      Vutuv.Activity.subscribe(a.id)
      send!(a, conversation)

      refute_receive {:new_message, _}
    end

    test "rejects non-participants" do
      [a, b, outsider] = [user(), user(), user()]
      conversation = insert_conversation_between(a, b)

      assert {:error, :not_participant} = Chat.send_message(outsider, conversation.id, "hi")
    end

    test "pending: the initiator may send exactly one message" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b, status: "pending", initiator: a)

      assert {:ok, %Message{}} = Chat.send_message(a, conversation.id, "request")
      assert {:error, :pending_limit} = Chat.send_message(a, conversation.id, "again")
    end

    test "pending: the recipient replying accepts the conversation" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b, status: "pending", initiator: a)
      send!(a, conversation, "request")

      assert {:ok, %Message{}} = Chat.send_message(b, conversation.id, "sure")
      assert Repo.get!(Conversation, conversation.id).status == "accepted"
      # The initiator can write freely again.
      assert {:ok, %Message{}} = Chat.send_message(a, conversation.id, "great")
    end

    test "declined: drops silently without a row or broadcast" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b, status: "declined", initiator: a)
      Chat.subscribe(conversation.id)

      assert {:ok, :dropped} = Chat.send_message(a, conversation.id, "hello?")
      assert Repo.aggregate(Message, :count) == 0
      refute_receive {:new_message, _}
    end

    test "rejects an empty or overlong body" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b)

      assert {:error, %Ecto.Changeset{}} = Chat.send_message(a, conversation.id, "   ")

      too_long = String.duplicate("x", Message.max_body_length() + 1)
      assert {:error, %Ecto.Changeset{}} = Chat.send_message(a, conversation.id, too_long)
    end
  end

  describe "accept_request/2 and decline_request/2" do
    setup do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b, status: "pending", initiator: a)
      send!(a, conversation, "request")
      %{a: a, b: b, conversation: conversation}
    end

    test "only the recipient may accept", %{a: a, b: b, conversation: conversation} do
      assert {:error, :not_recipient} = Chat.accept_request(a, conversation.id)
      assert {:ok, %Conversation{status: "accepted"}} = Chat.accept_request(b, conversation.id)
    end

    test "only the recipient may decline", %{a: a, b: b, conversation: conversation} do
      assert {:error, :not_recipient} = Chat.decline_request(a, conversation.id)
      assert {:ok, %Conversation{status: "declined"}} = Chat.decline_request(b, conversation.id)
    end

    test "declining hides it from the recipient and keeps it pending-looking for the sender",
         %{a: a, b: b, conversation: conversation} do
      {:ok, _} = Chat.decline_request(b, conversation.id)

      assert Chat.list_requests(b) == []
      assert Chat.list_conversations(b) == []
      assert Chat.get_conversation(b, conversation.id) == nil

      # The sender still sees the thread exactly like an unanswered request.
      assert [%{conversation: %Conversation{id: id}}] = Chat.list_conversations(a)
      assert id == conversation.id
    end

    test "accepting broadcasts a conversation update so the sender's open thread can refresh",
         %{b: b, conversation: conversation} do
      Chat.subscribe(conversation.id)
      conversation_id = conversation.id

      assert {:ok, %Conversation{status: "accepted"}} = Chat.accept_request(b, conversation.id)
      assert_receive {:conversation_updated, ^conversation_id}
    end

    test "declining stays silent on the conversation topic", %{b: b, conversation: conversation} do
      Chat.subscribe(conversation.id)

      assert {:ok, %Conversation{status: "declined"}} = Chat.decline_request(b, conversation.id)
      refute_receive {:conversation_updated, _}
    end

    test "accepting or declining a non-pending conversation fails", %{b: b} do
      [c, d] = [user(), user()]
      accepted = insert_conversation_between(c, d, status: "accepted")

      assert {:error, :not_recipient} = Chat.accept_request(d, accepted.id)
      assert {:error, :not_recipient} = Chat.accept_request(b, Vutuv.UUIDv7.generate())
    end
  end

  describe "list_conversations/1 and list_requests/1" do
    test "lists accepted conversations newest-activity-first with preview and unread count" do
      [me, x, y] = [user(), user(), user()]
      older = insert_conversation_between(me, x)
      newer = insert_conversation_between(me, y)

      backdate_message!(send!(x, older, "old ping"), 60)

      Repo.update_all(from(c in Conversation, where: c.id == ^older.id),
        set: [last_message_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -60)]
      )

      send!(y, newer, "fresh ping")
      Chat.mark_read(me, older.id)

      assert [first, second] = Chat.list_conversations(me)
      assert first.conversation.id == newer.id
      assert first.other.id == y.id
      assert first.last_body == "fresh ping"
      assert first.unread == 1
      assert second.conversation.id == older.id
      assert second.other.id == x.id
      assert second.unread == 0
    end

    test "the sender sees their own pending request in the list; the recipient does not" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b, status: "pending", initiator: a)
      send!(a, conversation, "request")

      assert [%{conversation: %Conversation{id: id}}] = Chat.list_conversations(a)
      assert id == conversation.id
      assert Chat.list_conversations(b) == []
    end

    test "requests are pending conversations with a message where I am the recipient" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b, status: "pending", initiator: a)

      # An empty pending conversation is not a request yet.
      assert Chat.list_requests(b) == []

      send!(a, conversation, "request")

      assert [%{conversation: %Conversation{id: id}, other: other, last_body: "request"}] =
               Chat.list_requests(b)

      assert id == conversation.id
      assert other.id == a.id
      assert Chat.list_requests(a) == []
    end
  end

  describe "messages_page/3" do
    test "paginates newest-first with a keyset cursor" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b)

      messages =
        for i <- 1..5 do
          backdate_message!(send!(a, conversation, "msg #{i}"), 60 - i)
        end

      page = Chat.messages_page(a, conversation.id, limit: 3)
      assert Enum.map(page.entries, & &1.body) == ["msg 5", "msg 4", "msg 3"]
      assert page.more?

      older = Chat.messages_page(a, conversation.id, limit: 3, cursor: page.next_cursor)
      assert Enum.map(older.entries, & &1.body) == ["msg 2", "msg 1"]
      refute older.more?
      assert older.next_cursor == nil

      # Senders come preloaded for rendering.
      assert %Vutuv.Accounts.User{} = hd(page.entries).sender
      assert length(messages) == 5
    end

    test "returns an empty page for non-participants" do
      [a, b, outsider] = [user(), user(), user()]
      conversation = insert_conversation_between(a, b)
      send!(a, conversation)

      assert %{entries: [], more?: false, next_cursor: nil} =
               Chat.messages_page(outsider, conversation.id)
    end
  end

  describe "mark_read/2 and unread_conversations_count/1" do
    test "counts conversations with unread messages, not messages" do
      [me, x, y] = [user(), user(), user()]
      first = insert_conversation_between(me, x)
      second = insert_conversation_between(me, y)

      send!(x, first, "one")
      send!(x, first, "two")
      send!(y, second, "three")

      assert Chat.unread_conversations_count(me) == 2
    end

    test "my own messages are never unread" do
      [me, x] = [user(), user()]
      conversation = insert_conversation_between(me, x)
      send!(me, conversation)

      assert Chat.unread_conversations_count(me) == 0
      assert Chat.unread_conversations_count(x) == 1
    end

    test "a pending request counts for the recipient" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b, status: "pending", initiator: a)
      send!(a, conversation, "request")

      assert Chat.unread_conversations_count(b) == 1
      assert Chat.unread_conversations_count(a) == 0
    end

    test "a declined conversation counts for nobody" do
      [a, b] = [user(), user()]
      conversation = insert_conversation_between(a, b, status: "pending", initiator: a)
      send!(a, conversation, "request")
      {:ok, _} = Chat.decline_request(b, conversation.id)

      assert Chat.unread_conversations_count(a) == 0
      assert Chat.unread_conversations_count(b) == 0
    end

    test "mark_read clears the unread count, resets notified_at and broadcasts" do
      [me, x] = [user(), user()]
      conversation = insert_conversation_between(me, x)
      send!(x, conversation)

      Repo.update_all(
        from(p in Participant,
          where: p.conversation_id == ^conversation.id and p.user_id == ^me.id
        ),
        set: [notified_at: NaiveDateTime.utc_now(:second)]
      )

      Vutuv.Activity.subscribe(me.id)
      assert :ok = Chat.mark_read(me, conversation.id)

      assert Chat.unread_conversations_count(me) == 0
      assert_receive :messages_read

      participant =
        Repo.get_by!(Participant, conversation_id: conversation.id, user_id: me.id)

      assert participant.last_read_at
      assert participant.notified_at == nil
    end

    test "a message arriving in the same wall-clock second as the read stays unread" do
      # Issue #776 (4b): the read marker is max(inserted_at). With second
      # precision a message landing in the same second as the read got
      # inserted_at == marker, so the strict `> last_read_at` test marked it
      # read. Microsecond inserted_at + last_read_at keep it unread.
      [me, x] = [user(), user()]
      conversation = insert_conversation_between(me, x)

      earlier = send!(x, conversation, "one")
      set_inserted_at!(earlier, ~N[2026-06-13 12:00:00.100000])

      :ok = Chat.mark_read(me, conversation.id)
      assert Chat.unread_conversations_count(me) == 0

      later = send!(x, conversation, "two")
      set_inserted_at!(later, ~N[2026-06-13 12:00:00.900000])

      assert Chat.unread_conversations_count(me) == 1
      assert [%{unread: 1}] = Chat.list_conversations(me)
    end

    test "nil user has no unread conversations" do
      assert Chat.unread_conversations_count(nil) == 0
    end
  end
end
