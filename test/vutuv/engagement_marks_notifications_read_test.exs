defmodule Vutuv.EngagementMarksNotificationsReadTest do
  @moduledoc """
  Answering, liking, bookmarking or reposting a post marks the notifications
  *about that post* as read (`Vutuv.Activity.mark_post_seen/2`).

  The bell badge is supposed to mean "things you have not looked at". Before
  this, it meant "things since your last visit to /notifications": you could
  read an answer in the feed, reply to it, and the badge still insisted there
  was one unread notification until you opened the page and dismissed it by
  hand. Four actions settle the question of whether a post was read — nobody
  answers, likes, bookmarks or reposts a post they have not looked at — so each
  of them now clears what the feed had to say about it.

  Deliberately narrow (see `Activity.subject_post_id/1`): only the three kinds
  whose subject is somebody *else's* post can be cleared this way. A "like"
  names your own post, and reposting or bookmarking your own post tells us
  nothing about whether you saw who liked it, so those keep waiting for a real
  visit to /notifications.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.PostsHelpers

  alias Vutuv.Activity
  alias Vutuv.Posts

  # A member whose handle can appear as `@handle` in a body (the factory's
  # default `user-1` is not mentionable, see Factory.unique_username/1).
  defp mentionable(attrs \\ []) do
    insert(:activated_user, Keyword.put_new(attrs, :username, unique_username()))
  end

  # My post, somebody else's answer to it: one unread "reply" notification.
  defp answered_post do
    me = insert(:user)
    other = insert(:user)
    mine = insert(:post, user: me)
    answer = insert(:post, user: other)
    insert(:post_reply, post: answer, parent_post: mine, parent_author: me)

    {me, answer}
  end

  describe "engaging with the post a notification is about" do
    test "answering it clears the notification" do
      {me, answer} = answered_post()
      assert Activity.unread_notification_count(me.id) == 1

      {:ok, _reply} = Posts.create_reply(me, answer, %{body: "Thanks!"})

      assert Activity.unread_notification_count(me.id) == 0
    end

    test "liking it clears the notification" do
      {me, answer} = answered_post()

      :ok = Posts.like_post(me, answer)

      assert Activity.unread_notification_count(me.id) == 0
    end

    test "bookmarking it clears the notification" do
      {me, answer} = answered_post()

      :ok = Posts.bookmark_post(me, answer)

      assert Activity.unread_notification_count(me.id) == 0
    end

    test "reposting it clears the notification" do
      {me, answer} = answered_post()

      :ok = Posts.repost_post(me, answer)

      assert Activity.unread_notification_count(me.id) == 0
    end

    test "undoing the engagement does not make it unread again" do
      # Reading cannot be undone: unliking says "I take that back", not
      # "I never saw it".
      {me, answer} = answered_post()

      :ok = Posts.like_post(me, answer)
      :ok = Posts.unlike_post(me, answer)

      assert Activity.unread_notification_count(me.id) == 0
    end

    test "a mention stops counting once the post that named me is liked" do
      author = mentionable()
      me = mentionable()

      post = create_post!(author, %{body: "Ask @#{me.username} about it."})
      assert Activity.unread_notification_count(me.id) == 1

      :ok = Posts.like_post(me, post)

      assert Activity.unread_notification_count(me.id) == 0
    end

    test "a thread event stops counting once its reply is answered" do
      me = insert(:user)
      first_replier = insert(:user)
      root = insert(:post, user: me)
      first = insert(:post, user: first_replier)
      insert(:post_reply, post: first, parent_post: root, parent_author: me, root_post: root)
      nested = insert(:post, user: insert(:user))

      insert(:post_reply,
        post: nested,
        parent_post: first,
        parent_author: first_replier,
        root_post: root
      )

      # One direct reply to my post + one answer elsewhere in my thread.
      assert Activity.unread_notification_count(me.id) == 2

      {:ok, _reply} = Posts.create_reply(me, nested, %{body: "Good point."})

      # Only the thread event goes; the unanswered direct reply stays unread.
      assert Activity.unread_notification_count(me.id) == 1
    end

    test "only the engaged post's notification goes, the rest stay unread" do
      {me, answer} = answered_post()
      insert(:follow, follower: insert(:user), followee: me)
      second = insert(:post, user: insert(:user))
      insert(:post_reply, post: second, parent_post: insert(:post, user: me), parent_author: me)

      assert Activity.unread_notification_count(me.id) == 3

      :ok = Posts.like_post(me, answer)

      assert Activity.unread_notification_count(me.id) == 2
    end
  end

  describe "what the notifications page still shows" do
    test "the row stays in the feed and in the pager's total" do
      # Read is not deleted: /notifications remains the log of what happened,
      # it just stops calling that row new.
      {me, answer} = answered_post()
      :ok = Posts.like_post(me, answer)

      assert [%{kind: "reply"}] = Activity.notifications_page(me.id, limit: 50).entries
      assert Activity.notifications_count(me.id) == 1
    end

    test "the row is marked as the subject post, so the page can render it read" do
      {me, answer} = answered_post()
      [item] = Activity.notifications_page(me.id, limit: 50).entries

      assert Activity.subject_post_id(item) == answer.id
      assert Activity.seen_post_ids(me.id, [answer.id]) |> Enum.to_list() == []

      :ok = Posts.like_post(me, answer)

      assert Activity.seen_post_ids(me.id, [answer.id]) |> Enum.to_list() == [answer.id]
    end

    test "a like on my own post has no subject post to clear" do
      # The deliberate limit: nothing I can do to my own post proves I saw who
      # liked it, so that badge waits for a real visit to /notifications.
      me = insert(:user)
      mine = insert(:post, user: me)
      :ok = Posts.like_post(insert(:user), mine)

      [item] = Activity.notifications_page(me.id, limit: 50).entries
      assert item.kind == "like"
      assert Activity.subject_post_id(item) == nil

      :ok = Posts.bookmark_post(me, mine)

      assert Activity.unread_notification_count(me.id) == 1
    end
  end

  describe "mark_posts_seen/2 (the feed's reveal pill)" do
    # Clicking "Show N new posts" reveals the whole pending batch at once, so
    # the feed marks them seen in one call: every notification whose subject
    # is one of the revealed posts stops counting, and the member's open
    # sessions get ONE recount signal for the batch, not one per post.
    test "clears the whole batch and recounts once" do
      me = insert(:user)
      other = insert(:user)
      mine = insert(:post, user: me)
      first = insert(:post, user: other)
      second = insert(:post, user: insert(:user))
      insert(:post_reply, post: first, parent_post: mine, parent_author: me)
      insert(:post_reply, post: second, parent_post: mine, parent_author: me)

      assert Activity.unread_notification_count(me.id) == 2

      Activity.subscribe(me.id)
      assert :ok = Activity.mark_posts_seen(me.id, [first.id, second.id])

      assert Activity.unread_notification_count(me.id) == 0
      assert_receive :notifications_changed
      refute_receive :notifications_changed
    end

    test "an already-seen batch stays silent (no recount for nothing)" do
      {me, answer} = answered_post()
      Activity.mark_post_seen(me.id, answer.id)

      Activity.subscribe(me.id)
      assert :ok = Activity.mark_posts_seen(me.id, [answer.id])

      refute_receive :notifications_changed
    end

    test "a nil member or an empty batch is a no-op" do
      post = insert(:post, user: insert(:user))
      assert Activity.mark_posts_seen(nil, [post.id]) == :ok
      assert Activity.mark_posts_seen(Vutuv.UUIDv7.generate(), []) == :ok
    end
  end

  describe "mark_post_seen/2" do
    test "tells the member's open sessions to recount their badge" do
      me = insert(:user)
      post = insert(:post, user: insert(:user))
      Activity.subscribe(me.id)

      Activity.mark_post_seen(me.id, post.id)

      assert_receive :notifications_changed
    end

    test "is idempotent" do
      {me, answer} = answered_post()

      Activity.mark_post_seen(me.id, answer.id)
      Activity.mark_post_seen(me.id, answer.id)

      assert Activity.seen_post_ids(me.id, [answer.id]) |> Enum.to_list() == [answer.id]
    end

    test "a nil member or post is a no-op" do
      post = insert(:post, user: insert(:user))
      assert Activity.mark_post_seen(nil, post.id) == :ok
      assert Activity.mark_post_seen(Vutuv.UUIDv7.generate(), nil) == :ok
    end

    test "seen_post_ids/2 asks nothing for an empty list or a logged-out visitor" do
      me = insert(:user)
      assert Activity.seen_post_ids(me.id, []) |> Enum.to_list() == []
      assert Activity.seen_post_ids(nil, [Vutuv.UUIDv7.generate()]) |> Enum.to_list() == []
    end
  end
end
