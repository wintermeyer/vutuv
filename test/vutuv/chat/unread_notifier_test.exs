defmodule Vutuv.Chat.UnreadNotifierTest do
  @moduledoc """
  The unread-message email is debounced: one email per conversation per unread
  burst, only once the newest unread message has sat unread past the delay,
  and re-armed by reading the conversation. Driven through
  `Vutuv.Chat.send_unread_notifications/0` (what the supervised ticker calls);
  the ticker itself is disabled in tests.
  """
  use Vutuv.DataCase, async: false
  import Swoosh.TestAssertions
  import Vutuv.ChatHelpers

  alias Vutuv.Chat
  alias Vutuv.Chat.{Message, Participant}

  # A activated user with an email row (the unread notifier mails the recipient).
  defp user(attrs \\ []) do
    user = insert(:activated_user, attrs)
    insert(:email, user: user)
    user
  end

  # Push a message far enough into the past that the debounce delay has passed.
  defp age_message!(message, minutes \\ 20) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -minutes * 60)
    Repo.update_all(from(m in Message, where: m.id == ^message.id), set: [inserted_at: at])
  end

  defp participant(conversation, user) do
    Repo.get_by!(Participant, conversation_id: conversation.id, user_id: user.id)
  end

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  test "emails the recipient of a message left unread past the delay, exactly once" do
    [a, b] = [user(), user(locale: "en")]
    conversation = insert_conversation_between(a, b)
    age_message!(send!(a, conversation))

    assert Chat.send_unread_notifications() == 1

    assert_email_sent(fn email ->
      assert email.subject =~ "@#{a.active_slug}"
      assert email.text_body =~ "messages/#{conversation.id}"
      assert email.headers["Auto-Submitted"] == "auto-generated"
    end)

    assert participant(conversation, b).notified_at

    # The burst was notified; nothing further until the conversation is read.
    assert Chat.send_unread_notifications() == 0
    refute_email_sent()
  end

  test "a German recipient gets the German email" do
    [a, b] = [user(), user(locale: "de")]
    conversation = insert_conversation_between(a, b)
    age_message!(send!(a, conversation))

    assert Chat.send_unread_notifications() == 1

    assert_email_sent(fn email ->
      assert email.subject == "Neue Nachricht von @#{a.active_slug} auf vutuv"
      assert email.text_body =~ "Nachricht"
    end)
  end

  test "stays silent while the newest unread message is younger than the delay" do
    [a, b] = [user(), user()]
    conversation = insert_conversation_between(a, b)
    send!(a, conversation)

    assert Chat.send_unread_notifications() == 0
    refute_email_sent()
  end

  test "stays silent when the conversation has been read" do
    [a, b] = [user(), user()]
    conversation = insert_conversation_between(a, b)
    age_message!(send!(a, conversation))
    Chat.mark_read(b, conversation.id)

    assert Chat.send_unread_notifications() == 0
    refute_email_sent()
  end

  test "reading the conversation re-arms the debounce for the next burst" do
    [a, b] = [user(), user()]
    conversation = insert_conversation_between(a, b)
    age_message!(send!(a, conversation))

    assert Chat.send_unread_notifications() == 1
    Chat.mark_read(b, conversation.id)
    # The second burst is older than the delay but newer than the read marker.
    age_message!(send!(a, conversation, "second burst"), 18)

    assert Chat.send_unread_notifications() == 1
  end

  test "a member who switched notification emails off is not emailed" do
    [a, b] = [user(), user(notification_emails?: false)]
    conversation = insert_conversation_between(a, b)
    age_message!(send!(a, conversation))

    assert Chat.send_unread_notifications() == 0
    refute_email_sent()
    # notified_at stays unset: switching the emails back on (edit profile)
    # makes the still-unread burst eligible again.
    assert participant(conversation, b).notified_at == nil
  end

  test "pending requests never email (strangers cannot trigger mail to anyone)" do
    [a, b] = [user(), user()]
    conversation = insert_conversation_between(a, b, status: "pending", initiator: a)
    age_message!(send!(a, conversation, "request"))

    assert Chat.send_unread_notifications() == 0
    refute_email_sent()
  end

  test "the sender of the unread message is not emailed" do
    [a, b] = [user(), user()]
    conversation = insert_conversation_between(a, b)
    age_message!(send!(a, conversation))

    assert Chat.send_unread_notifications() == 1
    assert participant(conversation, b).notified_at
    assert participant(conversation, a).notified_at == nil
  end
end
