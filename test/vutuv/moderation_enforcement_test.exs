defmodule Vutuv.ModerationEnforcementTest do
  use Vutuv.DataCase

  alias Vutuv.Accounts.User
  alias Vutuv.Chat
  alias Vutuv.Posts
  alias Vutuv.Search

  defp freeze_post!(post) do
    Repo.update_all(
      from(p in Posts.Post, where: p.id == ^post.id),
      set: [frozen_at: NaiveDateTime.utc_now(:second)]
    )

    Repo.get!(Posts.Post, post.id)
  end

  defp set_user!(user, fields) do
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: fields)
    Repo.get!(User, user.id)
  end

  defp feed_post_ids(viewer) do
    Posts.feed_page(viewer).entries |> Enum.map(& &1.post.id)
  end

  describe "frozen posts" do
    setup do
      author = insert(:activated_user)
      follower = insert(:activated_user)
      follow!(follower, author)
      post = insert(:post, user: author)
      {:ok, %{author: author, follower: follower, post: post}}
    end

    test "vanish for everyone but the author and admins", %{
      author: author,
      follower: follower,
      post: post
    } do
      post = freeze_post!(post)

      refute Posts.visible_to?(post, follower)
      refute Posts.visible_to?(post, nil)
      assert Posts.visible_to?(post, author)
      assert Posts.visible_to?(post, insert(:activated_user, admin?: true))
    end

    test "drop out of the follower's feed but stay in the author's", %{
      author: author,
      follower: follower,
      post: post
    } do
      assert post.id in feed_post_ids(follower)
      freeze_post!(post)

      refute post.id in feed_post_ids(follower)
      assert post.id in feed_post_ids(author)
    end

    test "drop off the profile for visitors but not the owner", %{
      author: author,
      follower: follower,
      post: post
    } do
      freeze_post!(post)

      refute post.id in Enum.map(Posts.profile_posts(author, follower), & &1.post.id)
      assert post.id in Enum.map(Posts.profile_posts(author, author), & &1.post.id)
    end
  end

  describe "posts of hidden accounts" do
    setup do
      author = insert(:activated_user)
      follower = insert(:activated_user)
      follow!(follower, author)
      post = insert(:post, user: author)
      {:ok, %{author: author, follower: follower, post: post}}
    end

    test "a frozen account's posts vanish for others", %{
      author: author,
      follower: follower,
      post: post
    } do
      set_user!(author, frozen_at: NaiveDateTime.utc_now(:second))

      refute post.id in feed_post_ids(follower)
      refute Posts.visible_to?(Repo.get!(Posts.Post, post.id), follower)
      assert post.id in feed_post_ids(author)
    end

    test "a suspended account's posts vanish until the suspension lapses", %{
      follower: follower,
      author: author,
      post: post
    } do
      set_user!(author, suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(:second), 3600))
      refute post.id in feed_post_ids(follower)

      set_user!(author, suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600))
      assert post.id in feed_post_ids(follower)
    end

    test "a deactivated account's posts vanish", %{follower: follower, author: author, post: post} do
      set_user!(author, deactivated_at: NaiveDateTime.utc_now(:second))
      refute post.id in feed_post_ids(follower)
    end
  end

  describe "frozen messages" do
    setup do
      sender = insert(:activated_user)
      other = insert(:activated_user)

      conversation =
        insert_conversation_between(sender, other,
          last_message_at: NaiveDateTime.utc_now(:second)
        )

      message = insert(:message, conversation: conversation, sender: sender)
      {:ok, %{sender: sender, other: other, conversation: conversation, message: message}}
    end

    test "hidden from the other participant, still visible to the sender", %{
      sender: sender,
      other: other,
      conversation: conversation,
      message: message
    } do
      Repo.update_all(
        from(m in Chat.Message, where: m.id == ^message.id),
        set: [frozen_at: NaiveDateTime.utc_now(:second)]
      )

      other_page = Chat.messages_page(other, conversation.id)
      refute message.id in Enum.map(other_page.entries, & &1.id)

      sender_page = Chat.messages_page(sender, conversation.id)
      assert message.id in Enum.map(sender_page.entries, & &1.id)
    end

    test "does not count as unread and does not leak into the sidebar preview", %{
      other: other,
      conversation: conversation,
      message: message
    } do
      Repo.update_all(
        from(m in Chat.Message, where: m.id == ^message.id),
        set: [frozen_at: NaiveDateTime.utc_now(:second)]
      )

      [entry] = Chat.list_conversations(other)
      assert entry.conversation.id == conversation.id
      assert entry.unread == 0
      refute entry.last_body == message.body
    end
  end

  describe "search" do
    defp searchable_user!(fields) do
      user = insert(:activated_user, fields)
      insert(:search_term, user: user, value: "findme-#{user.username}")
      user
    end

    test "hidden accounts disappear from name search" do
      visible = searchable_user!([])
      frozen = searchable_user!(frozen_at: NaiveDateTime.utc_now(:second))

      suspended =
        searchable_user!(suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(:second), 3600))

      deactivated = searchable_user!(deactivated_at: NaiveDateTime.utc_now(:second))

      found = Search.search("findme-", false) |> Enum.map(& &1.user_id)

      assert visible.id in found
      refute frozen.id in found
      refute suspended.id in found
      refute deactivated.id in found
    end

    test "hidden accounts disappear from email search" do
      frozen = insert(:activated_user, frozen_at: NaiveDateTime.utc_now(:second))
      insert(:email, user: frozen, value: "frozen-search@example.com")

      assert Search.search("frozen-search@example.com", true) == []
    end
  end
end
