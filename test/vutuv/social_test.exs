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

    test "a follow-back notifies both users of the new mutual connection" do
      a = insert(:user, first_name: "Anna", last_name: "A")
      b = insert(:user, first_name: "Ben", last_name: "B")
      {:ok, _} = Social.follow(a, b.id)

      Vutuv.Activity.subscribe(a.id)
      Vutuv.Activity.subscribe(b.id)

      assert {:ok, _} = Social.follow(b, a.id)

      # a gets the regular follower event plus the mutuality event ...
      assert_receive {:new_notification, %{kind: "follower", actor_name: "Ben B"}}
      assert_receive {:new_notification, %{kind: "connection", actor_name: "Ben B"}}
      # ... and b (who just followed back) learns the connection is now mutual.
      assert_receive {:new_notification, %{kind: "connection", actor_name: "Anna A"}}
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

  describe "groups" do
    test "create_group/2 creates a group" do
      user = insert(:user)
      assert {:ok, group} = Social.create_group(user, %{name: "Friends"})
      assert group.name == "Friends"
      assert group.user_id == user.id
    end
  end
end
