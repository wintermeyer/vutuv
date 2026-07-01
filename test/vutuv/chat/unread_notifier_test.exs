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
      assert email.subject =~ "@#{a.username}"
      assert email.text_body =~ "messages/#{conversation.id}"
      assert email.headers["Auto-Submitted"] == "auto-generated"
    end)

    assert participant(conversation, b).notified_at

    # The burst was notified; nothing further until the conversation is read.
    assert Chat.send_unread_notifications() == 0
    refute_email_sent()
  end

  test "quotes the first unread message and says it is the only email for the burst" do
    [a, b] = [user(), user(locale: "en")]
    conversation = insert_conversation_between(a, b)
    age_message!(send!(a, conversation, "Are you around for lunch tomorrow?"))
    # A later reply in the same burst must not change what is quoted: we mail
    # only the first message and the copy has to say so.
    send!(a, conversation, "still there?")

    assert Chat.send_unread_notifications() == 1

    assert_email_sent(fn email ->
      # The DM that triggered the email is included, in both bodies.
      assert email.text_body =~ "Are you around for lunch tomorrow?"
      assert email.html_body =~ "Are you around for lunch tomorrow?"
      # Only the first message is quoted, not the later one in the same burst.
      refute email.text_body =~ "still there?"
      # And the recipient is told this is the only email for the conversation.
      assert email.text_body =~ "only email"
    end)
  end

  test "the email links to the recipient's notification settings" do
    [a, b] = [user(), user(locale: "en")]
    conversation = insert_conversation_between(a, b)
    age_message!(send!(a, conversation))

    assert Chat.send_unread_notifications() == 1

    assert_email_sent(fn email ->
      assert email.text_body =~ "#{b.username}/settings/notifications"
      assert email.html_body =~ "#{b.username}/settings/notifications"
    end)
  end

  test "each-message mode sends one email per unread message" do
    [a, b] = [user(), user(dm_email_each_message?: true, locale: "en")]
    conversation = insert_conversation_between(a, b)
    age_message!(send!(a, conversation, "first message"))
    age_message!(send!(a, conversation, "second message"))

    assert Chat.send_unread_notifications() == 2

    assert_received {:email, one}
    assert_received {:email, two}
    bodies = [one.text_body, two.text_body]
    assert Enum.any?(bodies, &(&1 =~ "first message"))
    assert Enum.any?(bodies, &(&1 =~ "second message"))
    # The copy reflects the mode, not the "only email" line.
    assert Enum.all?(bodies, &(&1 =~ "every new unread message"))

    # The high-water mark means nothing is re-sent on the next sweep.
    assert Chat.send_unread_notifications() == 0
    refute_email_sent()
  end

  test "each-message mode mails only messages newer than the last sweep's mark" do
    [a, b] = [user(), user(dm_email_each_message?: true, locale: "en")]
    conversation = insert_conversation_between(a, b)
    old = send!(a, conversation, "already covered")
    fresh = send!(a, conversation, "new since last time")
    age_message!(old, 40)
    age_message!(fresh, 20)

    # Simulate a prior sweep whose high-water mark sits between the two messages:
    # the older one was mailed then, the newer one arrived after and is due now.
    mark = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -30 * 60)

    Repo.update_all(
      from(p in Participant,
        where: p.conversation_id == ^conversation.id and p.user_id == ^b.id
      ),
      set: [notified_at: mark]
    )

    assert Chat.send_unread_notifications() == 1
    assert_email_sent(fn email -> assert email.text_body =~ "new since last time" end)
  end

  test "respects a member's longer custom delay" do
    [a, b] = [user(), user(dm_email_delay_minutes: 30)]
    conversation = insert_conversation_between(a, b)
    message = send!(a, conversation)

    # Unread for 20 minutes: past the default 15, but not this member's 30.
    age_message!(message, 20)
    assert Chat.send_unread_notifications() == 0
    refute_email_sent()

    # Once it crosses 30 minutes, it goes out.
    age_message!(message, 35)
    assert Chat.send_unread_notifications() == 1
  end

  test "respects a member's shorter custom delay" do
    [a, b] = [user(), user(dm_email_delay_minutes: 5)]
    conversation = insert_conversation_between(a, b)
    # Unread for 10 minutes: still under the default 15, but past this member's 5.
    age_message!(send!(a, conversation), 10)

    assert Chat.send_unread_notifications() == 1
  end

  test "a German recipient gets the German email" do
    [a, b] = [user(), user(locale: "de")]
    conversation = insert_conversation_between(a, b)
    age_message!(send!(a, conversation))

    assert Chat.send_unread_notifications() == 1

    assert_email_sent(fn email ->
      assert email.subject == "Neue Nachricht von @#{a.username} auf vutuv"
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

  test "a moderation-frozen message does not trigger an unread email" do
    [a, b] = [user(), user()]
    conversation = insert_conversation_between(a, b)
    message = send!(a, conversation)
    age_message!(message)

    # A frozen message is hidden from the recipient (messages_page filters it),
    # so it must not light the unread email either.
    Repo.update_all(
      from(m in Message, where: m.id == ^message.id),
      set: [frozen_at: NaiveDateTime.utc_now(:second)]
    )

    assert Chat.send_unread_notifications() == 0
    refute_email_sent()
    assert participant(conversation, b).notified_at == nil
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
