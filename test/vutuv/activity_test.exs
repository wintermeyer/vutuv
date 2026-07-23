defmodule Vutuv.ActivityTest do
  use Vutuv.DataCase, async: true
  import Vutuv.QueryCounter

  alias Vutuv.Activity
  alias Vutuv.Posts.PostReply
  alias Vutuv.Social.Follow
  alias Vutuv.Tags.UserTagEndorsement

  test "notify broadcasts a :new_notification to the user topic" do
    user_id = Vutuv.UUIDv7.generate()
    Activity.subscribe(user_id)
    Activity.notify(user_id, %{kind: "follower", text: "Hi"})
    assert_receive {:new_notification, %{text: "Hi"}}
  end

  test "notify_new_follower carries the actor's name and action" do
    user_id = Vutuv.UUIDv7.generate()
    Activity.subscribe(user_id)
    Activity.notify_new_follower(user_id, %{first_name: "José", last_name: "Daniel"})

    assert_receive {:new_notification,
                    %{kind: "follower", actor_name: "José Daniel", text: "started following you."} =
                      n}

    # A bare map (not a %User{}) has no profile to link or avatar to show.
    assert n.actor_param == nil
    assert n.actor_avatar == nil
  end

  test "notify_endorsement carries the tag plus the actor triple" do
    user_id = Vutuv.UUIDv7.generate()
    Activity.subscribe(user_id)
    Activity.notify_endorsement(user_id, %{first_name: "Ada", last_name: "Lovelace"}, "Elixir")

    assert_receive {:new_notification, n}
    assert n.kind == "endorsement"
    assert n.tag == "Elixir"
    assert n.text == "endorsed you for Elixir."
    assert n.actor_name == "Ada Lovelace"
    # A bare map (not a %User{}) has no profile to link or avatar to show.
    assert n.actor_param == nil
    assert n.actor_avatar == nil
  end

  test "notify_connection carries the actor triple and no tag" do
    user_id = Vutuv.UUIDv7.generate()
    Activity.subscribe(user_id)
    Activity.notify_connection(user_id, %{first_name: "Wojtek", last_name: "Mach"})

    assert_receive {:new_notification, n}
    assert n.kind == "connection"
    assert n.text == "is now connected with you."
    assert n.actor_name == "Wojtek Mach"
    assert n.actor_param == nil
    assert n.actor_avatar == nil
    refute Map.has_key?(n, :tag)
  end

  test "a nil recipient is a no-op (no crash, nothing delivered)" do
    Activity.subscribe(Vutuv.UUIDv7.generate())
    assert :ok = Activity.notify(nil, %{text: "ignored"})
    refute_receive {:new_notification, _}
  end

  test "mark_notifications_read / mark_messages_read broadcast read events" do
    user_id = Vutuv.UUIDv7.generate()
    Activity.subscribe(user_id)
    Activity.mark_notifications_read(user_id)
    Activity.mark_messages_read(user_id)
    assert_receive :notifications_read
    assert_receive :messages_read
  end

  describe "notification feed entries" do
    test "derives follower events retroactively from existing connections" do
      me = insert(:user)
      follower = insert(:user, first_name: "Grace", last_name: "Hopper")
      connection = insert(:follow, follower: follower, followee: me)

      assert [n] = recent_notifications(me.id)
      assert n.kind == "follower"
      assert n.id == "follower-#{connection.id}"
      assert n.actor_name == "Grace Hopper"
      assert n.actor_param == follower.username
      assert %NaiveDateTime{} = n.at
    end

    test "derives endorsement events with the endorsed tag's name" do
      me = insert(:user)
      endorser = insert(:user, first_name: "Ada", last_name: "Lovelace")
      tag = insert(:tag, name: "Phoenix")
      user_tag = insert(:user_tag, user: me, tag: tag)
      insert(:user_tag_endorsement, user: endorser, user_tag: user_tag)

      assert [n] = recent_notifications(me.id)
      assert n.kind == "endorsement"
      assert n.tag == "Phoenix"
      assert n.actor_name == "Ada Lovelace"
      assert n.actor_param == endorser.username
      # Read side must carry the same actor triple as the live notify_* payload.
      assert Map.has_key?(n, :actor_avatar)
    end

    test "confirming the first PIN leaves a welcome note naming the own handle" do
      me = insert(:activated_user, welcome_notified_at: ~N[2026-07-23 09:00:00])

      assert [n] = recent_notifications(me.id)
      assert n.kind == "username"
      assert n.username == me.username
      assert n.id == "username-#{me.id}"
      assert n.at == ~N[2026-07-23 09:00:00]
      # Nobody did this to them, so the entry carries no actor at all.
      refute Map.has_key?(n, :actor_name)
    end

    # Everyone who signed up before the note existed keeps a clean feed: the
    # stamp is the gate, not the mere fact of being confirmed.
    test "an account from before the feature gets no welcome note" do
      me = insert(:activated_user)

      assert recent_notifications(me.id) == []
    end

    test "a self-endorsement produces no notification" do
      me = insert(:user)
      tag = insert(:tag)
      user_tag = insert(:user_tag, user: me, tag: tag)
      insert(:user_tag_endorsement, user: me, user_tag: user_tag)

      assert recent_notifications(me.id) == []
    end

    test "derives a connection event for both sides of a mutual follow" do
      me = insert(:user)
      other = insert(:user, first_name: "Wojtek", last_name: "Mach")
      # A mutual follow makes them vernetzt; each side's feed carries both the
      # follower event (the other's follow) and the derived connection event.
      connect!(me, other)

      kinds = me.id |> recent_notifications() |> Enum.map(& &1.kind)
      assert "follower" in kinds
      assert "connection" in kinds

      other_kinds = other.id |> recent_notifications() |> Enum.map(& &1.kind)
      assert "follower" in other_kinds
      assert "connection" in other_kinds
    end

    test "a one-way follow yields a follower event but no connection event" do
      me = insert(:user)
      follower = insert(:user)
      follow!(follower, me)

      kinds = me.id |> recent_notifications() |> Enum.map(& &1.kind)
      assert "follower" in kinds
      refute "connection" in kinds
    end

    test "derives like events for the post's author, except self-likes" do
      author = insert(:user)
      fan = insert(:user, first_name: "Fanny", last_name: "First")
      post = insert(:post, user: author)
      :ok = Vutuv.Posts.like_post(fan, post)
      :ok = Vutuv.Posts.like_post(author, post)

      assert [%{kind: "like", actor_name: "Fanny First"}] =
               author.id |> recent_notifications() |> Enum.filter(&(&1.kind == "like"))
    end

    test "a one-way follow produces no connection event" do
      me = insert(:user)
      insert(:follow, follower: insert(:user), followee: me)

      kinds = me.id |> recent_notifications() |> Enum.map(& &1.kind)
      refute "connection" in kinds
    end

    test "sorts newest first and respects the limit" do
      me = insert(:user)

      c1 = insert(:follow, follower: insert(:user, first_name: "Old"), followee: me)
      backdate_connection(c1, ~N[2020-01-01 12:00:00])

      tag = insert(:tag, name: "Elixir")
      user_tag = insert(:user_tag, user: me, tag: tag)

      e =
        insert(:user_tag_endorsement, user: insert(:user, first_name: "Mid"), user_tag: user_tag)

      backdate_endorsement(e, ~N[2023-01-01 12:00:00])

      c2 = insert(:follow, follower: insert(:user, first_name: "New"), followee: me)
      backdate_connection(c2, ~N[2026-01-01 12:00:00])

      assert [%{kind: "follower"}, %{kind: "endorsement"}, %{kind: "follower"}] =
               recent_notifications(me.id)

      assert [%{id: id1}, %{id: id2}] = recent_notifications(me.id, 2)
      assert id1 == "follower-#{c2.id}"
      assert id2 == "endorsement-#{e.id}"
    end

    test "another user's events do not leak in" do
      me = insert(:user)
      somebody_else = insert(:user)
      insert(:follow, follower: insert(:user), followee: somebody_else)

      assert recent_notifications(me.id) == []
    end

    test "derives reply events from post reply rows" do
      me = insert(:user)
      replier = insert(:user, first_name: "Joe", last_name: "Armstrong")
      parent = insert(:post, user: me)
      reply = insert(:post, user: replier)
      ref = insert(:post_reply, post: reply, parent_post: parent, parent_author: me)

      assert [n] = recent_notifications(me.id)
      assert n.kind == "reply"
      assert n.id == "reply-#{ref.id}"
      assert n.actor_name == "Joe Armstrong"
      assert n.actor_param == replier.username
      assert %NaiveDateTime{} = n.at
    end

    test "a self-reply produces no notification" do
      me = insert(:user)
      parent = insert(:post, user: me)
      reply = insert(:post, user: me)
      insert(:post_reply, post: reply, parent_post: parent, parent_author: me)

      assert recent_notifications(me.id) == []
    end

    test "a reply to a since-deleted post still notifies its author" do
      me = insert(:user)
      reply = insert(:post, user: insert(:user))
      insert(:post_reply, post: reply, parent_post: nil, parent_author: me)

      assert [%{kind: "reply"}] = recent_notifications(me.id)
    end
  end

  describe "notifications_page/2" do
    test "reports more? and hands out a cursor only when older events exist" do
      me = insert(:user)

      for i <- 1..3 do
        c = insert(:follow, follower: insert(:user), followee: me)
        backdate_connection(c, NaiveDateTime.add(~N[2024-01-01 12:00:00], i * 60))
      end

      page1 = Activity.notifications_page(me.id, limit: 2)
      assert [_, _] = page1.entries
      assert page1.more?
      assert page1.next_cursor

      page2 = Activity.notifications_page(me.id, limit: 2, cursor: page1.next_cursor)
      assert [_] = page2.entries
      refute page2.more?
      assert page2.next_cursor == nil
    end

    test "the cursor walks the feed newest-first without gaps or duplicates" do
      me = insert(:user)

      connections =
        for i <- 1..5 do
          c = insert(:follow, follower: insert(:user), followee: me)
          backdate_connection(c, NaiveDateTime.add(~N[2024-01-01 12:00:00], i * 60))
          c
        end

      assert [p1, p2, p3] = collect_pages(me.id, 2)
      assert [length(p1), length(p2), length(p3)] == [2, 2, 1]

      ids = Enum.map(p1 ++ p2 ++ p3, & &1.id)
      expected = connections |> Enum.reverse() |> Enum.map(&"follower-#{&1.id}")
      assert ids == expected
    end

    test "same-second ties spanning a page boundary neither skip nor duplicate" do
      me = insert(:user)
      at = ~N[2024-01-01 12:00:00]

      connections =
        for _ <- 1..5 do
          c = insert(:follow, follower: insert(:user), followee: me)
          backdate_connection(c, at)
          c
        end

      pages = collect_pages(me.id, 2)
      ids = pages |> List.flatten() |> Enum.map(& &1.id)

      assert Enum.map(pages, &length/1) == [2, 2, 1]
      assert Enum.sort(ids) == Enum.sort(Enum.map(connections, &"follower-#{&1.id}"))
    end

    test "ties across different event kinds dedupe across pages too" do
      me = insert(:user)
      at = ~N[2024-01-01 12:00:00]

      c = insert(:follow, follower: insert(:user), followee: me)
      backdate_connection(c, at)

      tag = insert(:tag)
      user_tag = insert(:user_tag, user: me, tag: tag)

      for _ <- 1..2 do
        e = insert(:user_tag_endorsement, user: insert(:user), user_tag: user_tag)
        backdate_endorsement(e, at)
      end

      pages = collect_pages(me.id, 1)
      ids = pages |> List.flatten() |> Enum.map(& &1.id)

      assert length(ids) == 3
      assert Enum.uniq(ids) == ids
    end

    test "an exact page fit reports no further page" do
      me = insert(:user)

      for i <- 1..2 do
        c = insert(:follow, follower: insert(:user), followee: me)
        backdate_connection(c, NaiveDateTime.add(~N[2024-01-01 12:00:00], i * 60))
      end

      page = Activity.notifications_page(me.id, limit: 2)
      assert [_, _] = page.entries
      refute page.more?
      assert page.next_cursor == nil
    end

    test "kinds: restricts the feed to the named event kinds" do
      me = insert(:user)

      # One follower event and one like event.
      insert(:follow, follower: insert(:user), followee: me)
      post = insert(:post, user: me)
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      all = Activity.notifications_page(me.id)
      assert Enum.map(all.entries, & &1.kind) |> Enum.sort() == ["follower", "like"]

      posts_only = Activity.notifications_page(me.id, kinds: ["like", "reply"])
      assert Enum.map(posts_only.entries, & &1.kind) == ["like"]

      people_only = Activity.notifications_page(me.id, kinds: ["follower", "connection"])
      assert Enum.map(people_only.entries, & &1.kind) == ["follower"]
    end

    test "kinds: keeps its own pagination consistent" do
      me = insert(:user)
      # Interleave: likes are the filtered kind, follows are noise between them.
      for i <- 1..3 do
        post = insert(:post, user: me)
        :ok = Vutuv.Posts.like_post(insert(:user), post)
        backdate_like(post, NaiveDateTime.add(~N[2024-01-01 12:00:00], i * 60))
        c = insert(:follow, follower: insert(:user), followee: me)
        backdate_connection(c, NaiveDateTime.add(~N[2024-01-01 12:00:30], i * 60))
      end

      page1 = Activity.notifications_page(me.id, limit: 2, kinds: ["like"])
      assert Enum.map(page1.entries, & &1.kind) == ["like", "like"]
      assert page1.more?

      page2 =
        Activity.notifications_page(me.id, limit: 2, kinds: ["like"], cursor: page1.next_cursor)

      assert Enum.map(page2.entries, & &1.kind) == ["like"]
      refute page2.more?
    end

    test "page: walks the same feed by numbered page, newest first" do
      me = insert(:user)

      follows =
        for i <- 1..5 do
          follow = insert(:follow, follower: insert(:user), followee: me)
          backdate_connection(follow, NaiveDateTime.add(~N[2024-01-01 12:00:00], i * 60))
          follow
        end

      newest_first = follows |> Enum.reverse() |> Enum.map(&"follower-#{&1.id}")

      page1 = Activity.notifications_page(me.id, limit: 2, page: 1)
      page2 = Activity.notifications_page(me.id, limit: 2, page: 2)
      page3 = Activity.notifications_page(me.id, limit: 2, page: 3)

      assert Enum.map(page1.entries ++ page2.entries ++ page3.entries, & &1.id) == newest_first
      assert page1.more? and page2.more?
      refute page3.more?
      # An offset page carries no cursor.
      assert page1.next_cursor == nil
    end

    test "page: past the end is simply empty, and page 0/negative reads as page 1" do
      me = insert(:user)
      insert(:follow, follower: insert(:user), followee: me)

      assert Activity.notifications_page(me.id, limit: 2, page: 9).entries == []
      assert [_] = Activity.notifications_page(me.id, limit: 2, page: 0).entries
    end

    test "page: honours kinds:, so a filtered tab pages through its own events" do
      me = insert(:user)
      post = insert(:post, user: me)

      for i <- 1..3 do
        :ok = Vutuv.Posts.like_post(insert(:user), post)
        backdate_like(post, NaiveDateTime.add(~N[2024-01-01 12:00:00], i * 60))
        follow = insert(:follow, follower: insert(:user), followee: me)
        backdate_connection(follow, NaiveDateTime.add(~N[2024-01-01 12:00:30], i * 60))
      end

      page1 = Activity.notifications_page(me.id, limit: 2, page: 1, kinds: ["like"])
      page2 = Activity.notifications_page(me.id, limit: 2, page: 2, kinds: ["like"])

      assert Enum.map(page1.entries, & &1.kind) == ["like", "like"]
      assert Enum.map(page2.entries, & &1.kind) == ["like"]
      refute page2.more?
    end
  end

  describe "activity_summary/2" do
    test "counts recent events per kind in one map" do
      me = insert(:user)

      # Two followers, one of them mutual (also a connection), one like, one
      # endorsement — all now, so they land inside the window.
      insert(:follow, follower: insert(:user), followee: me)
      connect!(me, insert(:user))

      post = insert(:post, user: me)
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      user_tag = insert(:user_tag, user: me, tag: insert(:tag))
      insert(:user_tag_endorsement, user: insert(:user), user_tag: user_tag)

      since = NaiveDateTime.add(NaiveDateTime.utc_now(), -30, :day)
      summary = Activity.activity_summary(me.id, since)

      assert summary.followers == 2
      assert summary.connections == 1
      assert summary.likes == 1
      assert summary.endorsements == 1
      assert summary.replies == 0
    end

    test "events older than the window are not counted" do
      me = insert(:user)
      c = insert(:follow, follower: insert(:user), followee: me)
      backdate_connection(c, ~N[2016-11-24 12:00:00])

      since = NaiveDateTime.add(NaiveDateTime.utc_now(), -30, :day)
      assert Activity.activity_summary(me.id, since).followers == 0
    end
  end

  describe "unread_notification_count/1" do
    test "counts all events when the user has never read notifications" do
      me = insert(:user)
      insert(:follow, follower: insert(:user), followee: me)

      tag = insert(:tag)
      user_tag = insert(:user_tag, user: me, tag: tag)
      insert(:user_tag_endorsement, user: insert(:user), user_tag: user_tag)

      assert Activity.unread_notification_count(me.id) == 2
    end

    test "counts only events newer than the read marker" do
      me = insert(:user)

      old = insert(:follow, follower: insert(:user), followee: me)
      backdate_connection(old, ~N[2020-01-01 12:00:00])

      Activity.mark_notifications_read(me.id)
      assert Activity.unread_notification_count(me.id) == 0

      new = insert(:follow, follower: insert(:user), followee: me)
      backdate_connection(new, ~N[2099-01-01 12:00:00])

      assert Activity.unread_notification_count(me.id) == 1
    end

    test "is zero for a logged-out visitor (nil id)" do
      assert Activity.unread_notification_count(nil) == 0
    end

    test "equals the sum of the feed sources for a mixed constellation" do
      me = insert(:user)

      # One mutual follow (a follower event + a derived connection event) plus
      # one more plain incoming follower, one endorsement and one like.
      # Sources: 2 followers + 1 connection + 1 endorsement + 1 like.
      mutual = insert(:user)
      connect!(me, mutual)
      insert(:follow, follower: insert(:user), followee: me)

      tag = insert(:tag)
      user_tag = insert(:user_tag, user: me, tag: tag)
      insert(:user_tag_endorsement, user: insert(:user), user_tag: user_tag)

      :ok = Vutuv.Posts.like_post(insert(:user), insert(:post, user: me))

      sources =
        me.id |> recent_notifications() |> Enum.frequencies_by(& &1.kind)

      assert sources == %{
               "follower" => 2,
               "connection" => 1,
               "endorsement" => 1,
               "like" => 1
             }

      # The collapsed single-query count must still equal that source total (5).
      assert Activity.unread_notification_count(me.id) == 5
    end

    test "folds the marker read and the source counts into two queries" do
      me = insert(:user)
      insert(:follow, follower: insert(:user), followee: me)

      # One read for the notifications_read_at marker, one combined count query.
      assert {_, 2} = count_queries(fn -> Activity.unread_notification_count(me.id) end)
    end

    test "counts reply events, except self-replies" do
      me = insert(:user)
      parent = insert(:post, user: me)
      insert(:post_reply, post: insert(:post), parent_post: parent, parent_author: me)
      insert(:post_reply, post: insert(:post, user: me), parent_post: parent, parent_author: me)

      assert Activity.unread_notification_count(me.id) == 1
    end

    test "the read marker anchors to reply events too" do
      me = insert(:user)
      parent = insert(:post, user: me)

      old = insert(:post_reply, post: insert(:post), parent_post: parent, parent_author: me)
      backdate_reply(old, ~N[2020-01-01 12:00:00])

      # Like the same-second connection test above: with only a reply in the
      # feed the marker must anchor to it, not the wall clock, or a reply
      # landing in the marking second would be swallowed.
      now_second = NaiveDateTime.utc_now(:second)
      Activity.mark_notifications_read(me.id)
      assert Activity.unread_notification_count(me.id) == 0

      fresh = insert(:post_reply, post: insert(:post), parent_post: parent, parent_author: me)
      backdate_reply(fresh, now_second)

      assert Activity.unread_notification_count(me.id) == 1
    end
  end

  describe "notifications_count/2" do
    test "counts the whole derived feed regardless of the read marker" do
      me = insert(:user)
      insert(:follow, follower: insert(:user), followee: me)

      tag = insert(:tag)
      user_tag = insert(:user_tag, user: me, tag: tag)
      insert(:user_tag_endorsement, user: insert(:user), user_tag: user_tag)

      Activity.mark_notifications_read(me.id)

      assert Activity.unread_notification_count(me.id) == 0
      assert Activity.notifications_count(me.id) == 2
    end

    test "is zero for a logged-out visitor (nil id)" do
      assert Activity.notifications_count(nil) == 0
    end

    test "counts the whole feed in a single query (no marker read needed)" do
      me = insert(:user)
      insert(:follow, follower: insert(:user), followee: me)

      assert {_, 1} = count_queries(fn -> Activity.notifications_count(me.id) end)
    end

    test "kinds: counts only those sources, so a filtered pager matches its list" do
      me = insert(:user)
      insert(:follow, follower: insert(:user), followee: me)
      post = insert(:post, user: me)
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      assert Activity.notifications_count(me.id, ["like", "reply"]) == 1
      assert Activity.notifications_count(me.id, ["follower", "connection"]) == 1
      assert Activity.notifications_count(me.id, ["moderation"]) == 0
      assert Activity.notifications_count(me.id, nil) == 2
    end

    test "a filtered count is a single query too" do
      me = insert(:user)
      insert(:follow, follower: insert(:user), followee: me)

      assert {_, 1} = count_queries(fn -> Activity.notifications_count(me.id, ["follower"]) end)
    end

    test "every feed source is counted: the kinds of the count match the feed's" do
      # The count-side kind list must not drift from the feed-side one, or a
      # filter tab's pager would count events its list does not show (or miss
      # some). Both go through the same public seams here.
      me = insert(:user)

      insert(:follow, follower: insert(:user), followee: me)
      post = insert(:post, user: me)
      :ok = Vutuv.Posts.like_post(insert(:user), post)
      tag = insert(:tag)
      user_tag = insert(:user_tag, user: me, tag: tag)
      insert(:user_tag_endorsement, user: insert(:user), user_tag: user_tag)

      for kind <- ["follower", "like", "endorsement"] do
        entries = Activity.notifications_page(me.id, kinds: [kind]).entries
        assert Activity.notifications_count(me.id, [kind]) == length(entries)
      end
    end
  end

  describe "mark_notifications_read/1 persistence" do
    test "stores the read marker and still broadcasts" do
      me = insert(:user)
      old = insert(:follow, follower: insert(:user), followee: me)
      backdate_connection(old, ~N[2020-01-01 12:00:00])
      assert Activity.unread_notification_count(me.id) == 1

      Activity.subscribe(me.id)
      Activity.mark_notifications_read(me.id)

      assert_receive :notifications_read
      assert Activity.unread_notification_count(me.id) == 0
      assert Repo.get!(Vutuv.Accounts.User, me.id).notifications_read_at
    end

    test "an event landing in the same second as the mark still counts as unread" do
      me = insert(:user)
      # Everything the user has seen so far is comfortably in the past, so the
      # read marker should land back there, not on the current wall clock.
      old = insert(:follow, follower: insert(:user), followee: me)
      backdate_connection(old, ~N[2020-01-01 12:00:00])

      # Capture the second the (buggy) wall-clock marker would stamp, mark read,
      # then file a brand-new event in that very second. With a wall-clock
      # marker plus a strict `>` comparison the new event ties the marker and is
      # silently dropped; the marker must instead trail the last seen event.
      now_second = NaiveDateTime.utc_now(:second)
      Activity.mark_notifications_read(me.id)
      assert Activity.unread_notification_count(me.id) == 0

      fresh = insert(:follow, follower: insert(:user), followee: me)
      backdate_connection(fresh, now_second)

      assert Activity.unread_notification_count(me.id) == 1
    end
  end

  # Test shorthand for the first page's entries.
  defp recent_notifications(user_id, limit \\ 50) do
    Activity.notifications_page(user_id, limit: limit).entries
  end

  # Walk the feed page by page until the context says there is nothing older.
  defp collect_pages(user_id, limit, cursor \\ nil) do
    page = Activity.notifications_page(user_id, limit: limit, cursor: cursor)

    if page.more? do
      [page.entries | collect_pages(user_id, limit, page.next_cursor)]
    else
      [page.entries]
    end
  end

  # Timestamps have second precision, so same-second inserts tie; backdating
  # gives each event a distinct, deterministic time.
  defp backdate_connection(%Follow{id: id}, at) do
    Repo.update_all(from(c in Follow, where: c.id == ^id), set: [inserted_at: at])
  end

  defp backdate_endorsement(%UserTagEndorsement{id: id}, at) do
    Repo.update_all(from(e in UserTagEndorsement, where: e.id == ^id), set: [inserted_at: at])
  end

  defp backdate_reply(%PostReply{id: id}, at) do
    Repo.update_all(from(r in PostReply, where: r.id == ^id), set: [inserted_at: at])
  end

  defp backdate_like(post, at) do
    Repo.update_all(
      from(l in Vutuv.Posts.PostLike, where: l.post_id == ^post.id),
      set: [inserted_at: at]
    )
  end
end
