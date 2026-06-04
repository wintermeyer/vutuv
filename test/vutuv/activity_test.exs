defmodule Vutuv.ActivityTest do
  use Vutuv.DataCase

  alias Vutuv.Activity
  alias Vutuv.Social.Connection
  alias Vutuv.Tags.UserTagEndorsement

  test "notify broadcasts a :new_notification to the user topic" do
    Activity.subscribe(42)
    Activity.notify(42, %{kind: "follower", text: "Hi"})
    assert_receive {:new_notification, %{text: "Hi"}}
  end

  test "notify_new_follower carries the actor's name and action" do
    Activity.subscribe(7)
    Activity.notify_new_follower(7, %{first_name: "José", last_name: "Daniel"})

    assert_receive {:new_notification,
                    %{kind: "follower", actor_name: "José Daniel", text: "started following you."} =
                      n}

    # A bare map (not a %User{}) has no profile to link or avatar to show.
    assert n.actor_param == nil
    assert n.actor_avatar == nil
  end

  test "a nil recipient is a no-op (no crash, nothing delivered)" do
    Activity.subscribe(13)
    assert :ok = Activity.notify(nil, %{text: "ignored"})
    refute_receive {:new_notification, _}
  end

  test "mark_notifications_read / mark_messages_read broadcast read events" do
    Activity.subscribe(9)
    Activity.mark_notifications_read(9)
    Activity.mark_messages_read(9)
    assert_receive :notifications_read
    assert_receive :messages_read
  end

  describe "recent_notifications/2" do
    test "derives follower events retroactively from existing connections" do
      me = insert(:user)
      follower = insert(:user, first_name: "Grace", last_name: "Hopper")
      connection = insert(:connection, follower: follower, followee: me)

      assert [n] = Activity.recent_notifications(me.id)
      assert n.kind == "follower"
      assert n.id == "follower-#{connection.id}"
      assert n.actor_name == "Grace Hopper"
      assert n.actor_param == follower.active_slug
      assert %NaiveDateTime{} = n.at
    end

    test "derives endorsement events with the endorsed tag's name" do
      me = insert(:user)
      endorser = insert(:user, first_name: "Ada", last_name: "Lovelace")
      tag = insert(:tag, name: "Phoenix")
      user_tag = insert(:user_tag, user: me, tag: tag)
      insert(:user_tag_endorsement, user: endorser, user_tag: user_tag)

      assert [n] = Activity.recent_notifications(me.id)
      assert n.kind == "endorsement"
      assert n.tag == "Phoenix"
      assert n.actor_name == "Ada Lovelace"
      assert n.actor_param == endorser.active_slug
    end

    test "a self-endorsement produces no notification" do
      me = insert(:user)
      tag = insert(:tag)
      user_tag = insert(:user_tag, user: me, tag: tag)
      insert(:user_tag_endorsement, user: me, user_tag: user_tag)

      assert Activity.recent_notifications(me.id) == []
    end

    test "derives a connection event when the follow is mutual" do
      me = insert(:user)
      other = insert(:user, first_name: "Wojtek", last_name: "Mach")
      insert(:connection, follower: other, followee: me)
      insert(:connection, follower: me, followee: other)

      kinds = me.id |> Activity.recent_notifications() |> Enum.map(& &1.kind)
      # The incoming follow shows up as usual, plus the mutuality event.
      assert "follower" in kinds
      assert "connection" in kinds
    end

    test "a one-way follow produces no connection event" do
      me = insert(:user)
      insert(:connection, follower: insert(:user), followee: me)

      kinds = me.id |> Activity.recent_notifications() |> Enum.map(& &1.kind)
      refute "connection" in kinds
    end

    test "sorts newest first and respects the limit" do
      me = insert(:user)

      c1 = insert(:connection, follower: insert(:user, first_name: "Old"), followee: me)
      backdate_connection(c1, ~N[2020-01-01 12:00:00])

      tag = insert(:tag, name: "Elixir")
      user_tag = insert(:user_tag, user: me, tag: tag)

      e =
        insert(:user_tag_endorsement, user: insert(:user, first_name: "Mid"), user_tag: user_tag)

      backdate_endorsement(e, ~N[2023-01-01 12:00:00])

      c2 = insert(:connection, follower: insert(:user, first_name: "New"), followee: me)
      backdate_connection(c2, ~N[2026-01-01 12:00:00])

      assert [%{kind: "follower"}, %{kind: "endorsement"}, %{kind: "follower"}] =
               Activity.recent_notifications(me.id)

      assert [%{id: id1}, %{id: id2}] = Activity.recent_notifications(me.id, 2)
      assert id1 == "follower-#{c2.id}"
      assert id2 == "endorsement-#{e.id}"
    end

    test "another user's events do not leak in" do
      me = insert(:user)
      somebody_else = insert(:user)
      insert(:connection, follower: insert(:user), followee: somebody_else)

      assert Activity.recent_notifications(me.id) == []
    end
  end

  describe "notifications_page/2" do
    test "reports more? and hands out a cursor only when older events exist" do
      me = insert(:user)

      for i <- 1..3 do
        c = insert(:connection, follower: insert(:user), followee: me)
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
          c = insert(:connection, follower: insert(:user), followee: me)
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
          c = insert(:connection, follower: insert(:user), followee: me)
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

      c = insert(:connection, follower: insert(:user), followee: me)
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
        c = insert(:connection, follower: insert(:user), followee: me)
        backdate_connection(c, NaiveDateTime.add(~N[2024-01-01 12:00:00], i * 60))
      end

      page = Activity.notifications_page(me.id, limit: 2)
      assert [_, _] = page.entries
      refute page.more?
      assert page.next_cursor == nil
    end
  end

  describe "unread_notification_count/1" do
    test "counts all events when the user has never read notifications" do
      me = insert(:user)
      insert(:connection, follower: insert(:user), followee: me)

      tag = insert(:tag)
      user_tag = insert(:user_tag, user: me, tag: tag)
      insert(:user_tag_endorsement, user: insert(:user), user_tag: user_tag)

      assert Activity.unread_notification_count(me.id) == 2
    end

    test "counts only events newer than the read marker" do
      me = insert(:user)

      old = insert(:connection, follower: insert(:user), followee: me)
      backdate_connection(old, ~N[2020-01-01 12:00:00])

      Activity.mark_notifications_read(me.id)
      assert Activity.unread_notification_count(me.id) == 0

      new = insert(:connection, follower: insert(:user), followee: me)
      backdate_connection(new, ~N[2099-01-01 12:00:00])

      assert Activity.unread_notification_count(me.id) == 1
    end

    test "is zero for a logged-out visitor (nil id)" do
      assert Activity.unread_notification_count(nil) == 0
    end
  end

  describe "mark_notifications_read/1 persistence" do
    test "stores the read marker and still broadcasts" do
      me = insert(:user)
      old = insert(:connection, follower: insert(:user), followee: me)
      backdate_connection(old, ~N[2020-01-01 12:00:00])
      assert Activity.unread_notification_count(me.id) == 1

      Activity.subscribe(me.id)
      Activity.mark_notifications_read(me.id)

      assert_receive :notifications_read
      assert Activity.unread_notification_count(me.id) == 0
      assert Repo.get!(Vutuv.Accounts.User, me.id).notifications_read_at
    end
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
  defp backdate_connection(%Connection{id: id}, at) do
    Repo.update_all(from(c in Connection, where: c.id == ^id), set: [inserted_at: at])
  end

  defp backdate_endorsement(%UserTagEndorsement{id: id}, at) do
    Repo.update_all(from(e in UserTagEndorsement, where: e.id == ^id), set: [inserted_at: at])
  end
end
