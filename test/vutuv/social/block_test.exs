defmodule Vutuv.Social.BlockTest do
  @moduledoc """
  Blocking (`Vutuv.Social.block_user/2`): severs follows + connection both
  ways, freezes the 1:1 conversation, and refuses every new interaction in
  both directions (follow, connect, message, reply, like, repost) while the
  block stands. Unblocking lifts the enforcement but restores nothing —
  deliberately unlike a rejected moderation report, which puts severed ties
  back.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.{Chat, Posts, Social}
  alias Vutuv.Chat.Conversation
  alias Vutuv.Social.{Block, Connection, Follow}

  setup do
    Vutuv.RateLimiter.reset()
    {:ok, blocker: insert(:activated_user), blocked: insert(:activated_user)}
  end

  defp block!(blocker, blocked) do
    {:ok, block} = Social.block_user(blocker, blocked)
    block
  end

  describe "block_user/2" do
    test "concurrent double-block is idempotent, not a crash", %{blocker: a, blocked: b} do
      results = Task.await_many(for _ <- 1..2, do: Task.async(fn -> Social.block_user(a, b) end))

      assert Enum.all?(results, &match?({:ok, %Block{}}, &1))
      assert Repo.aggregate(from(b in Block, where: b.blocker_id == ^a.id), :count) == 1
    end

    test "severs follows and connection both ways and freezes the conversation", %{
      blocker: a,
      blocked: b
    } do
      insert(:follow, follower: a, followee: b)
      insert(:follow, follower: b, followee: a)
      {:ok, _} = Social.request_connection(a, b)
      conversation = insert_conversation_between(a, b)

      block!(a, b)

      assert Repo.all(Follow) == []
      assert Repo.all(Connection) == []
      assert Repo.get!(Conversation, conversation.id).frozen_at
    end

    test "blocking yourself is refused", %{blocker: a} do
      assert {:error, :self} = Social.block_user(a, a)
    end

    test "is idempotent", %{blocker: a, blocked: b} do
      block = block!(a, b)
      assert {:ok, %Block{id: id}} = Social.block_user(a, b)
      assert id == block.id
    end

    test "blocked_between?/2 sees both directions", %{blocker: a, blocked: b} do
      refute Social.blocked_between?(a.id, b.id)
      block!(a, b)
      assert Social.blocked_between?(a.id, b.id)
      assert Social.blocked_between?(b.id, a.id)
    end
  end

  describe "enforcement while blocked" do
    setup %{blocker: a, blocked: b} do
      block!(a, b)
      :ok
    end

    test "neither side can follow the other", %{blocker: a, blocked: b} do
      assert {:error, :blocked} = Social.follow(a, b.id)
      assert {:error, :blocked} = Social.follow(b, a.id)
      assert Repo.all(Follow) == []
    end

    test "neither side can request a connection", %{blocker: a, blocked: b} do
      assert {:error, :blocked} = Social.request_connection(a, b)
      assert {:error, :blocked} = Social.request_connection(b, a)
    end

    test "no new conversation can be opened, indistinguishable from a freeze", %{
      blocker: a,
      blocked: b
    } do
      assert {:error, :frozen} = Chat.find_or_create_conversation(b, a)
      assert {:error, :frozen} = Chat.find_or_create_conversation(a, b)
    end

    test "messages into the pre-existing (now frozen) conversation are dropped silently" do
      a = insert(:activated_user)
      b = insert(:activated_user)
      conversation = insert_conversation_between(a, b)
      {:ok, _} = Social.block_user(a, b)

      assert {:ok, :dropped} = Chat.send_message(b, conversation.id, "hello?")
    end

    test "replies to the blocked party's posts are refused", %{blocker: a, blocked: b} do
      post_by_a = create_post!(a, %{body: "public musings"})
      post_by_b = create_post!(b, %{body: "other musings"})

      assert {:error, :restricted} = Posts.create_reply(b, post_by_a, %{body: "reply"})
      assert {:error, :restricted} = Posts.create_reply(a, post_by_b, %{body: "reply"})
    end

    test "likes and reposts across the block are refused", %{blocker: a, blocked: b} do
      post_by_a = create_post!(a, %{body: "public musings"})

      assert {:error, :blocked} = Posts.like_post(b, post_by_a)
      assert {:error, :blocked} = Posts.repost_post(b, post_by_a)
    end

    test "reposts by third parties do not carry a blocked author into the feed", %{
      blocker: a,
      blocked: b
    } do
      # a follows c; c reposts a post by b (whom a blocked). a's feed must
      # not show it, although c is followed and the post is public.
      c = insert(:activated_user)
      {:ok, _} = Social.follow(a, c.id)
      post_by_b = create_post!(b, %{body: "reposted into the feed"})
      :ok = Posts.repost_post(c, post_by_b)

      entries = Posts.feed_page(a).entries
      refute Enum.any?(entries, fn e -> e.post.id == post_by_b.id end)

      # Sanity: c's own feed does carry it.
      assert Enum.any?(Posts.feed_page(c).entries, fn e -> e.post.id == post_by_b.id end)
    end
  end

  describe "unblock_user/2" do
    test "lifts the enforcement but restores nothing", %{blocker: a, blocked: b} do
      insert(:follow, follower: a, followee: b)
      block = block!(a, b)
      assert block

      :ok = Social.unblock_user(a, b)

      refute Social.blocked_between?(a.id, b.id)
      # Nothing restored - the old follow stays gone...
      assert Repo.all(Follow) == []
      # ...but new interaction is possible again.
      assert {:ok, _} = Social.follow(a, b.id)
    end

    test "unfreezes the conversation its own block froze", %{blocker: a, blocked: b} do
      conversation = insert_conversation_between(a, b)
      block!(a, b)
      assert Repo.get!(Conversation, conversation.id).frozen_at

      :ok = Social.unblock_user(a, b)

      assert Repo.get!(Conversation, conversation.id).frozen_at == nil
    end

    test "keeps the conversation frozen while the reverse block stands", %{
      blocker: a,
      blocked: b
    } do
      conversation = insert_conversation_between(a, b)
      block!(a, b)
      block!(b, a)

      :ok = Social.unblock_user(a, b)

      assert Repo.get!(Conversation, conversation.id).frozen_at
    end

    test "unblocking when no block exists is a no-op", %{blocker: a, blocked: b} do
      assert :ok = Social.unblock_user(a, b)
    end
  end

  describe "list_blocked/1" do
    test "lists the members I blocked, newest first", %{blocker: a, blocked: b} do
      c = insert(:activated_user)
      block!(a, b)
      block!(a, c)

      slugs = a |> Social.list_blocked() |> Enum.map(& &1.blocked.active_slug)
      assert slugs == [c.active_slug, b.active_slug]
    end
  end
end
