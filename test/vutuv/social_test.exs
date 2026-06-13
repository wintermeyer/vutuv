defmodule Vutuv.SocialTest do
  use Vutuv.DataCase

  alias Vutuv.Social

  describe "follow/2" do
    test "creates a connection between two users" do
      follower = insert(:user)
      followee = insert(:user)

      assert {:ok, connection} = Social.follow(follower.id, followee.id)
      assert connection.follower_id == follower.id
      assert connection.followee_id == followee.id
    end

    test "prevents self-follow" do
      user = insert(:user)
      assert {:error, changeset} = Social.follow(user.id, user.id)
      assert changeset.errors[:follower_id]
    end

    test "accepts an already-loaded follower struct" do
      # Controllers hold the session user struct; passing it avoids the
      # redundant Repo.get that the id-based variant needs for the notification.
      follower = insert(:user)
      followee = insert(:user)

      Vutuv.Activity.subscribe(followee.id)

      assert {:ok, connection} = Social.follow(follower, followee.id)
      assert connection.follower_id == follower.id

      assert_receive {:new_notification, %{kind: "follower", actor_param: _}}
    end

    test "a one-way follow does not emit a connection event" do
      follower = insert(:user)
      followee = insert(:user)

      Vutuv.Activity.subscribe(follower.id)
      Vutuv.Activity.subscribe(followee.id)

      assert {:ok, _} = Social.follow(follower, followee.id)

      assert_receive {:new_notification, %{kind: "follower"}}
      refute_receive {:new_notification, %{kind: "connection"}}
    end

    test "a follow-back no longer fires a connection event (connections are explicit now)" do
      a = insert(:user, first_name: "Anna", last_name: "A")
      b = insert(:user, first_name: "Ben", last_name: "B")
      {:ok, _} = Social.follow(a, b.id)

      Vutuv.Activity.subscribe(a.id)
      Vutuv.Activity.subscribe(b.id)

      assert {:ok, _} = Social.follow(b, a.id)

      # The follow-back is just a follow now; a connection only comes from the
      # consented request/accept flow (see Vutuv.ConnectionsTest).
      assert_receive {:new_notification, %{kind: "follower", actor_name: "Ben B"}}
      refute_receive {:new_notification, %{kind: "connection"}}
    end
  end

  describe "follower_count/1 and followee_count/1" do
    test "returns correct counts" do
      user = insert(:user, activated?: true)
      follower1 = insert(:user, activated?: true)
      follower2 = insert(:user, activated?: true)

      {:ok, _} = Social.follow(follower1.id, user.id)
      {:ok, _} = Social.follow(follower2.id, user.id)

      assert Social.follower_count(user) == 2
      assert Social.followee_count(user) == 0
      assert Social.followee_count(follower1) == 1
    end

    test "ignores follows from unactivated accounts" do
      user = insert(:user, activated?: true)
      unactivated = insert(:user)

      {:ok, _} = Social.follow(unactivated.id, user.id)

      assert Social.follower_count(user) == 0
      assert Social.followee_count(unactivated) == 1
    end

    test "ignores moderation-hidden accounts, but only on the listed side" do
      user = insert(:user, activated?: true)
      frozen = insert(:user, activated?: true, frozen_at: ~N[2026-01-01 00:00:00])

      {:ok, _} = Social.follow(frozen.id, user.id)
      {:ok, _} = Social.follow(user.id, frozen.id)

      assert Social.follower_count(user) == 0
      assert Social.followee_count(user) == 0

      # The frozen member views their own lists through the moderation
      # bypass; the visible other side must still show up there.
      assert Social.follower_count(frozen) == 1
      assert Social.followee_count(frozen) == 1
    end
  end

  describe "follows_page/3" do
    test "lists no moderation-hidden people" do
      user = insert(:user, activated?: true)
      visible = insert(:user, activated?: true)
      frozen = insert(:user, activated?: true, frozen_at: ~N[2026-01-01 00:00:00])

      {:ok, _} = Social.follow(visible.id, user.id)
      {:ok, _} = Social.follow(frozen.id, user.id)
      {:ok, _} = Social.follow(user.id, frozen.id)

      assert %{users: [%{id: visible_id}], total: 1} =
               Social.follows_page(user, :followers, %{})

      assert visible_id == visible.id

      assert %{users: [], total: 0} = Social.follows_page(user, :followees, %{})

      # The frozen member's own pages still show the visible side.
      assert %{users: [%{id: user_id}], total: 1} =
               Social.follows_page(frozen, :followers, %{})

      assert user_id == user.id
    end
  end

  describe "request_connection/2" do
    test "simultaneous mutual requests converge to an accepted connection" do
      a = insert(:activated_user)
      b = insert(:activated_user)

      results =
        Task.await_many([
          Task.async(fn -> Social.request_connection(a, b) end),
          Task.async(fn -> Social.request_connection(b, a) end)
        ])

      # Whoever loses the insert race must land in the mutual-desire branch
      # (auto-accept), not surface a unique-constraint changeset error.
      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert [%{status: "accepted"}] = Repo.all(Vutuv.Social.Connection)
    end
  end

  describe "list_connections/1 and connection_count/1" do
    test "hide members an admin hid after the connection formed" do
      user = insert(:user, activated?: true)
      visible = insert(:user, activated?: true)
      later_frozen = insert(:user, activated?: true)

      connect!(user, visible)
      connect!(user, later_frozen)

      later_frozen
      |> Ecto.Changeset.change(frozen_at: ~N[2026-01-01 00:00:00])
      |> Repo.update!()

      assert Social.connection_count(user) == 1
      assert [%{user: %{id: visible_id}}] = Social.list_connections(user)
      assert visible_id == visible.id

      # The frozen member still sees their own connections (moderation
      # bypass on their own pages).
      assert Social.connection_count(later_frozen) == 1
      assert [%{user: %{id: other_id}}] = Social.list_connections(later_frozen)
      assert other_id == user.id
    end
  end

  describe "user_follows_user?/2" do
    test "returns true when following" do
      user1 = insert(:user)
      user2 = insert(:user)
      {:ok, _} = Social.follow(user1.id, user2.id)

      assert Social.user_follows_user?(user1.id, user2.id)
    end

    test "returns false when not following" do
      user1 = insert(:user)
      user2 = insert(:user)

      refute Social.user_follows_user?(user1.id, user2.id)
    end
  end

  describe "most_followed_users/1" do
    test "hides unactivated and moderation-hidden accounts despite their followers" do
      # Every other public surface (search, follower counts) gates on
      # activated? + Moderation.Query.account_hidden; the public most-followed
      # listing and the "Who to follow" rail must too.
      popular = insert(:user, activated?: true)
      unactivated = insert(:user)
      frozen = insert(:user, activated?: true, frozen_at: ~N[2026-01-01 00:00:00])
      deactivated = insert(:user, activated?: true, deactivated_at: ~N[2026-01-01 00:00:00])

      follow!(insert(:user), popular)

      for hidden <- [unactivated, frozen, deactivated] do
        for _ <- 1..2, do: follow!(insert(:user), hidden)
      end

      ids = Social.most_followed_users(10) |> Enum.map(& &1.id)

      assert popular.id in ids
      refute unactivated.id in ids
      refute frozen.id in ids
      refute deactivated.id in ids
    end

    test "ranks by VISIBLE followers only, not ghost/hidden ones" do
      # The ranking must match the follower_count shown on each profile, and
      # must not be inflatable with never-activated follower accounts.
      x = insert(:user, activated?: true, first_name: "Xavier")
      y = insert(:user, activated?: true, first_name: "Yara")

      # X: one real follower + two that don't count (unactivated + hidden).
      follow!(insert(:user, activated?: true), x)
      follow!(insert(:user), x)
      follow!(insert(:user, activated?: true, frozen_at: ~N[2026-01-01 00:00:00]), x)

      # Y: two real followers.
      follow!(insert(:user, activated?: true), y)
      follow!(insert(:user, activated?: true), y)

      ids = Social.most_followed_users(10)
      assert Social.follower_count(x) == 1
      assert Social.follower_count(y) == 2

      x_rank = Enum.find_index(ids, &(&1.id == x.id))
      y_rank = Enum.find_index(ids, &(&1.id == y.id))
      assert y_rank < x_rank
    end

    test "returns the fields the listing rows render" do
      user = insert(:user, activated?: true, honorific_prefix: "Dr.")
      follow!(insert(:user, activated?: true), user)

      assert [row] = Social.most_followed_users(1)
      assert row.id == user.id
      assert row.active_slug == user.active_slug
      assert row.first_name == user.first_name
      assert row.honorific_prefix == "Dr."
    end
  end

  describe "create_membership/2" do
    test "ignores a smuggled follow_id" do
      owner = insert(:user)
      followee = insert(:user)
      {:ok, follow} = Social.follow(owner.id, followee.id)
      {:ok, group} = Social.create_group(owner, %{name: "Friends"})

      other = insert(:user)
      {:ok, other_follow} = Social.follow(other.id, followee.id)

      assert {:ok, membership} =
               Social.create_membership(follow, %{
                 "group_id" => group.id,
                 "follow_id" => other_follow.id
               })

      assert membership.follow_id == follow.id
    end

    test "rejects another user's group" do
      owner = insert(:user)
      {:ok, follow} = Social.follow(owner.id, insert(:user).id)
      {:ok, foreign_group} = Social.create_group(insert(:user), %{name: "Not yours"})

      assert {:error, changeset} =
               Social.create_membership(follow, %{"group_id" => foreign_group.id})

      assert errors_on(changeset)[:group_id]
    end

    test "requires a group" do
      owner = insert(:user)
      {:ok, follow} = Social.follow(owner.id, insert(:user).id)

      assert {:error, changeset} = Social.create_membership(follow, %{})
      assert errors_on(changeset)[:group_id]
    end
  end

  describe "groups" do
    test "create_group/2 ignores a smuggled user_id" do
      user = insert(:user)
      victim = insert(:user)

      assert {:ok, group} = Social.create_group(user, %{"name" => "Mine", "user_id" => victim.id})
      assert group.user_id == user.id
    end

    test "update_group/2 cannot re-home the group" do
      user = insert(:user)
      {:ok, group} = Social.create_group(user, %{name: "Mine"})

      assert {:ok, updated} =
               Social.update_group(group, %{"name" => "Renamed", "user_id" => insert(:user).id})

      assert updated.user_id == user.id
    end

    test "create_group/2 requires a name" do
      assert {:error, changeset} = Social.create_group(insert(:user), %{})
      assert errors_on(changeset)[:name]
    end

    test "create_group/2 creates a group" do
      user = insert(:user)
      assert {:ok, group} = Social.create_group(user, %{name: "Friends"})
      assert group.name == "Friends"
      assert group.user_id == user.id
    end
  end
end
