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
      user = insert(:user, email_confirmed?: true)
      follower1 = insert(:user, email_confirmed?: true)
      follower2 = insert(:user, email_confirmed?: true)

      {:ok, _} = Social.follow(follower1.id, user.id)
      {:ok, _} = Social.follow(follower2.id, user.id)

      assert Social.follower_count(user) == 2
      assert Social.followee_count(user) == 0
      assert Social.followee_count(follower1) == 1
    end

    test "ignores follows from unactivated accounts" do
      user = insert(:user, email_confirmed?: true)
      unactivated = insert(:user)

      {:ok, _} = Social.follow(unactivated.id, user.id)

      assert Social.follower_count(user) == 0
      assert Social.followee_count(unactivated) == 1
    end

    test "ignores moderation-hidden accounts, but only on the listed side" do
      user = insert(:user, email_confirmed?: true)
      frozen = insert(:user, email_confirmed?: true, frozen_at: ~N[2026-01-01 00:00:00])

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
      user = insert(:user, email_confirmed?: true)
      visible = insert(:user, email_confirmed?: true)
      frozen = insert(:user, email_confirmed?: true, frozen_at: ~N[2026-01-01 00:00:00])

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
      user = insert(:user, email_confirmed?: true)
      visible = insert(:user, email_confirmed?: true)
      later_frozen = insert(:user, email_confirmed?: true)

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
      # email_confirmed? + Moderation.Query.account_hidden; the public most-followed
      # listing and the "Who to follow" rail must too.
      popular = insert(:user, email_confirmed?: true)
      unactivated = insert(:user)
      frozen = insert(:user, email_confirmed?: true, frozen_at: ~N[2026-01-01 00:00:00])
      deactivated = insert(:user, email_confirmed?: true, deactivated_at: ~N[2026-01-01 00:00:00])
      suspended = insert(:user, email_confirmed?: true, suspended_until: ~N[2099-01-01 00:00:00])

      # A real (visible) follower, so the popular control legitimately ranks:
      # the listing shows members with at least one visible follower.
      follow!(insert(:user, email_confirmed?: true), popular)

      for hidden <- [unactivated, frozen, deactivated, suspended] do
        for _ <- 1..2, do: follow!(insert(:user, email_confirmed?: true), hidden)
      end

      ids = Social.most_followed_users(10) |> Enum.map(& &1.id)

      assert popular.id in ids
      refute unactivated.id in ids
      refute frozen.id in ids
      refute deactivated.id in ids
      refute suspended.id in ids
    end

    test "ranks by VISIBLE followers only, not ghost/hidden ones" do
      # The ranking must match the follower_count shown on each profile, and
      # must not be inflatable with never-activated follower accounts.
      x = insert(:user, email_confirmed?: true, first_name: "Xavier")
      y = insert(:user, email_confirmed?: true, first_name: "Yara")

      # X: one real follower + two that don't count (unactivated + hidden).
      follow!(insert(:user, email_confirmed?: true), x)
      follow!(insert(:user), x)
      follow!(insert(:user, email_confirmed?: true, frozen_at: ~N[2026-01-01 00:00:00]), x)

      # Y: two real followers.
      follow!(insert(:user, email_confirmed?: true), y)
      follow!(insert(:user, email_confirmed?: true), y)

      ids = Social.most_followed_users(10)
      assert Social.follower_count(x) == 1
      assert Social.follower_count(y) == 2

      x_rank = Enum.find_index(ids, &(&1.id == x.id))
      y_rank = Enum.find_index(ids, &(&1.id == y.id))
      assert y_rank < x_rank
    end

    test "returns the fields the listing rows render" do
      user = insert(:user, email_confirmed?: true, honorific_prefix: "Dr.")
      follow!(insert(:user, email_confirmed?: true), user)

      assert [row] = Social.most_followed_users(1)
      assert row.id == user.id
      assert row.username == user.username
      assert row.first_name == user.first_name
      assert row.honorific_prefix == "Dr."

      # updated_at is loaded so listing-rendered avatars get the cache-busting
      # ?v= token (Vutuv.Uploads). Without it a member's re-uploaded thumbnail
      # would stay cached-stale on every listing for up to 30 days.
      assert row.updated_at
      assert Vutuv.Avatar.url({"selfie.jpg", row}, :thumb) =~ ~r/\?v=\d+$/
    end
  end

  describe "liking and bookmarking a person" do
    alias Vutuv.Social.UserBookmark

    test "like/bookmark a stranger with no follow or connection, idempotently" do
      me = insert(:user)
      stranger = insert(:user)

      assert :ok = Social.like_user(me, stranger)
      assert :ok = Social.like_user(me, stranger)
      assert :ok = Social.bookmark_user(me, stranger)

      assert %{liked?: true, bookmarked?: true} = Social.user_saved_flags(me, stranger)
      # A save changes neither the follow nor the connection graph.
      refute Social.user_follows_user?(me.id, stranger.id)
      refute Social.connected?(me.id, stranger.id)
    end

    test "you cannot save yourself" do
      me = insert(:user)
      assert {:error, :self} = Social.like_user(me, me)
      assert {:error, :self} = Social.bookmark_user(me, me)
    end

    test "a save is refused across a block in either direction" do
      me = insert(:user)
      other = insert(:user)
      {:ok, _} = Social.block_user(me, other)

      assert {:error, :blocked} = Social.like_user(me, other)
      assert {:error, :blocked} = Social.bookmark_user(other, me)
      assert %{liked?: false, bookmarked?: false} = Social.user_saved_flags(me, other)
    end

    test "unlike / unbookmark clears the flag (idempotent)" do
      me = insert(:user)
      other = insert(:user)
      :ok = Social.like_user(me, other)
      :ok = Social.bookmark_user(me, other)

      assert :ok = Social.unlike_user(me, other)
      assert :ok = Social.unlike_user(me, other)
      assert :ok = Social.unbookmark_user(me, other)
      assert %{liked?: false, bookmarked?: false} = Social.user_saved_flags(me, other)
    end

    test "a real save broadcasts on the actor's activity topic; a no-op does not" do
      me = insert(:user)
      other = insert(:user)
      Vutuv.Activity.subscribe(me.id)

      :ok = Social.bookmark_user(me, other)
      assert_receive {:user_engagement_changed, %{kind: :bookmark, active?: true}}

      # The idempotent repeat is not news.
      :ok = Social.bookmark_user(me, other)
      refute_receive {:user_engagement_changed, _}

      :ok = Social.unbookmark_user(me, other)
      assert_receive {:user_engagement_changed, %{kind: :bookmark, active?: false}}
    end

    test "bookmarked_users_page paginates newest-saved-first and sorts by name" do
      me = insert(:user)
      anna = insert(:user, email_confirmed?: true, first_name: "Anna", last_name: "Zett")
      bert = insert(:user, email_confirmed?: true, first_name: "Bert", last_name: "Adam")

      # Save Anna earlier than Bert so the recency order is deterministic.
      :ok = Social.bookmark_user(me, anna)
      backdate_save(UserBookmark, me, anna, -60)
      :ok = Social.bookmark_user(me, bert)

      page1 = Social.bookmarked_users_page(me, limit: 1)
      assert [%{id: bert_id}] = page1.entries
      assert bert_id == bert.id
      assert page1.more?

      page2 = Social.bookmarked_users_page(me, limit: 1, offset: page1.next_offset)
      assert [%{id: anna_id}] = page2.entries
      assert anna_id == anna.id
      refute page2.more?

      # Oldest first flips the order; alphabetical sorts by name.
      assert [%{id: ^anna_id}, %{id: ^bert_id}] =
               Social.bookmarked_users_page(me, sort: :oldest).entries

      names = Social.bookmarked_users_page(me, sort: :name).entries |> Enum.map(& &1.first_name)
      assert names == ["Anna", "Bert"]
    end

    test "liked_users_page filters by search over name, @handle and headline" do
      me = insert(:user)

      match =
        insert(:user,
          email_confirmed?: true,
          first_name: "Charlie",
          last_name: "Brown",
          headline: "PHP wizard"
        )

      miss =
        insert(:user,
          email_confirmed?: true,
          first_name: "Dana",
          last_name: "Smith",
          headline: "Ruby dev"
        )

      :ok = Social.like_user(me, match)
      :ok = Social.like_user(me, miss)

      assert [%{id: id}] = Social.liked_users_page(me, search: "charlie").entries
      assert id == match.id
      assert [%{id: ^id}] = Social.liked_users_page(me, search: "php").entries
    end

    test "saved lists hide a member who is now blocked" do
      me = insert(:user)
      blocked = insert(:user, email_confirmed?: true)
      :ok = Social.bookmark_user(me, blocked)
      assert [_] = Social.bookmarked_users_page(me).entries

      {:ok, _} = Social.block_user(me, blocked)
      assert [] = Social.bookmarked_users_page(me).entries
    end

    # Backdates an engagement row so the newest-saved order is deterministic
    # (bookmark_user stamps NaiveDateTime second-precision; same-second rows
    # would otherwise tie).
    defp backdate_save(schema, %{id: user_id}, %{id: target_id}, seconds) do
      at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), seconds)

      {1, _} =
        Vutuv.Repo.update_all(
          Ecto.Query.from(e in schema,
            where: e.user_id == ^user_id and e.target_user_id == ^target_id
          ),
          set: [inserted_at: at]
        )

      :ok
    end
  end
end
