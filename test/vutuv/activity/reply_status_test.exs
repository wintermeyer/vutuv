defmodule Vutuv.Activity.ReplyStatusTest do
  use Vutuv.DataCase, async: true

  import Vutuv.PostsHelpers

  alias Vutuv.Activity
  alias Vutuv.Activity.ReplyStatus
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostRemoteReply

  @words ~w(reply thread mention fediverse_reply)

  # The factory's `user-<n>` handle carries a hyphen, which a mention never
  # matches, so the reader gets a handle-shaped one.
  defp reader, do: insert(:user, username: "reader#{System.unique_integer([:positive])}")

  # One of each kind that carries somebody's words, all addressed to `me`.
  defp one_of_each(me) do
    mine = insert(:post, user: me, body: "My question")
    {:ok, reply} = Posts.create_reply(insert(:user), mine, %{body: "An answer"})
    {:ok, thread} = Posts.create_reply(insert(:user), reply, %{body: "Deeper"})
    naming = create_post!(insert(:activated_user), %{body: "Ask @#{me.username}."})
    note = insert(:note, post: mine, content_text: "From elsewhere")

    %{mine: mine, reply: reply, thread: thread, naming: naming, note: note}
  end

  defp answer_note!(me, note) do
    post = insert(:post, user: me, body: "Thanks, over there")

    Repo.insert!(%PostRemoteReply{
      post_id: post.id,
      note_id: note.id,
      in_reply_to_uri: note.object_uri,
      actor_uri: note.actor_uri
    })

    post
  end

  defp kinds(me, answer) do
    %{entries: entries} =
      Activity.notifications_page(me.id, kinds: @words, answer: answer, page: 1, limit: 50)

    entries |> Enum.map(& &1.kind) |> Enum.sort()
  end

  describe "the answer: filter on the feed" do
    test "splits every kind with words into open and answered, and counts agree" do
      me = reader()
      %{reply: reply, naming: naming, note: note} = one_of_each(me)

      assert kinds(me, :open) == ~w(fediverse_reply mention reply thread)
      assert kinds(me, :answered) == []

      {:ok, _} = Posts.create_reply(me, reply, %{body: "Thank you"})
      {:ok, _} = Posts.create_reply(me, naming, %{body: "Sure"})
      answer_note!(me, note)

      assert kinds(me, :open) == ~w(thread)
      assert kinds(me, :answered) == ~w(fediverse_reply mention reply)

      assert Activity.notifications_count(me.id, @words, :open) == 1
      assert Activity.notifications_count(me.id, @words, :answered) == 3
      assert Activity.notifications_count(me.id, @words, nil) == 4
    end

    test "a reply of mine whose parent is gone does not empty the open list" do
      # `parent_post_id` nilifies when the post answered is deleted; one NULL in
      # the `NOT IN` list would make :open false for every row.
      me = reader()
      one_of_each(me)
      insert(:post_reply, post: insert(:post, user: me), parent_post: nil, parent_author: nil)

      assert kinds(me, :open) == ~w(fediverse_reply mention reply thread)
      assert Activity.notifications_count(me.id, @words, :open) == 4
    end

    test "a remote answer whose note was collected does not empty the open list" do
      me = reader()
      one_of_each(me)
      other_note = insert(:note, post: insert(:post, user: me))
      answer_note!(me, other_note)
      Repo.delete!(other_note)

      assert Activity.notifications_count(me.id, @words, :open) == 4
    end

    test "leaves the kinds without words alone" do
      me = reader()
      post = insert(:post, user: me)
      :ok = Posts.like_post(insert(:user), post)

      assert Activity.notifications_count(me.id, ["like"], :open) == 1
      assert Activity.notifications_count(me.id, ["like"], :answered) == 1
    end
  end

  describe "put/2" do
    test "names my newest answer and whether I liked it, per entry" do
      me = reader()
      %{reply: reply, thread: thread, note: note} = one_of_each(me)

      {:ok, first} = Posts.create_reply(me, reply, %{body: "First go"})
      {:ok, second} = Posts.create_reply(me, reply, %{body: "Second go"})

      Repo.update_all(from(p in Post, where: p.id == ^first.id),
        set: [inserted_at: ~N[2020-01-01 00:00:00]]
      )

      :ok = Posts.like_post(me, thread)
      remote_answer = answer_note!(me, note)

      %{entries: entries} = Activity.notifications_page(me.id, kinds: @words, page: 1, limit: 50)
      by_kind = me |> ReplyStatus.put(entries) |> Map.new(&{&1.kind, &1})

      assert by_kind["reply"].answer.id == second.id
      refute by_kind["reply"].liked?
      assert by_kind["thread"].answer == nil
      assert by_kind["thread"].liked?
      assert by_kind["mention"].answer == nil
      assert by_kind["fediverse_reply"].answer.id == remote_answer.id
    end

    test "another member's answer is not mine" do
      me = reader()
      %{reply: reply} = one_of_each(me)
      {:ok, _} = Posts.create_reply(insert(:user), reply, %{body: "Not me"})

      %{entries: entries} =
        Activity.notifications_page(me.id, kinds: ["reply"], page: 1, limit: 50)

      assert [%{answer: nil, liked?: false}] = ReplyStatus.put(me, entries)
    end
  end
end
