defmodule Vutuv.MentionNotificationsTest do
  @moduledoc """
  The `"mention"` notification kind: being named `@handle` in a post is news,
  wherever that post sits.

  Before this existed, a post that named you notified you only by accident —
  if it happened to be a direct answer to your own post ("reply") or to land in
  a thread you had written in ("thread"). A mention in a standalone post, or in
  a thread you are not part of, reached nobody. Both halves are covered here:
  the write side (`Vutuv.Posts` reconciling `post_mentions` and pushing live)
  and the read side (`Vutuv.Activity`'s derived feed, its unread count and the
  precedence against reply/thread).
  """
  use Vutuv.DataCase, async: true

  import Vutuv.PostsHelpers

  alias Vutuv.Activity
  alias Vutuv.Posts
  alias Vutuv.Posts.PostMention
  alias Vutuv.Social

  # A member whose handle can actually appear as `@handle` in a body (the
  # factory's default `user-1` is not mentionable, see Factory.unique_username/1).
  defp mentionable(attrs \\ []) do
    insert(:activated_user, Keyword.put_new(attrs, :username, unique_username()))
  end

  defp notifications(user_id), do: Activity.notifications_page(user_id, limit: 50).entries

  defp kinds(user_id), do: user_id |> notifications() |> Enum.frequencies_by(& &1.kind)

  describe "recording mentions" do
    test "a post naming a member records the mention and pushes it live" do
      author = mentionable()
      mentioned = mentionable()
      Activity.subscribe(mentioned.id)

      post = create_post!(author, %{body: "Ask @#{mentioned.username} about it."})
      post_id = post.id

      assert_receive {:new_notification, %{kind: "mention", post_id: ^post_id} = n}
      assert n.actor_param == author.username
      assert [%PostMention{user_id: user_id}] = Repo.all(PostMention)
      assert user_id == mentioned.id
    end

    test "several mentions in one body each get a row, a repeat only one" do
      author = mentionable()
      first = mentionable()
      second = mentionable()

      create_post!(author, %{
        body: "@#{first.username} and @#{second.username} — again @#{first.username}!"
      })

      assert Repo.all(PostMention) |> Enum.map(& &1.user_id) |> Enum.sort() ==
               Enum.sort([first.id, second.id])
    end

    test "mentioning yourself is not news" do
      author = mentionable()
      Activity.subscribe(author.id)

      create_post!(author, %{body: "As @#{author.username} always says…"})

      refute_receive {:new_notification, %{kind: "mention"}}, 50
      assert Repo.all(PostMention) == []
      assert kinds(author.id) == %{}
    end

    test "a handle inside a code span is sample text, not a mention" do
      author = mentionable()
      mentioned = mentionable()

      create_post!(author, %{body: "Type `@#{mentioned.username}` to mention them."})

      assert Repo.all(PostMention) == []
      assert kinds(mentioned.id) == %{}
    end

    test "an organization handle notifies nobody (organizations have no feed)" do
      author = mentionable()
      org = insert(:organization, username: unique_username())

      create_post!(author, %{body: "Now hiring at @#{org.username}."})

      assert Repo.all(PostMention) == []
    end

    test "an edit that adds a mention notifies the newly named member only" do
      author = mentionable()
      first = mentionable()
      second = mentionable()
      post = create_post!(author, %{body: "Hello @#{first.username}."})

      # Both topics feed this one mailbox, so a second push would show up here
      # — which is the point: exactly one member is newly named.
      Activity.subscribe(first.id)
      Activity.subscribe(second.id)

      {:ok, _} =
        Posts.update_post(post, %{body: "Hello @#{first.username} and @#{second.username}."})

      post_id = post.id
      assert_receive {:new_notification, %{kind: "mention", post_id: ^post_id}}
      refute_receive {:new_notification, %{kind: "mention"}}, 50

      assert kinds(first.id) == %{"mention" => 1}
      assert kinds(second.id) == %{"mention" => 1}
    end

    test "an edit that drops a mention drops the event with it" do
      author = mentionable()
      mentioned = mentionable()
      post = create_post!(author, %{body: "Hello @#{mentioned.username}."})
      assert kinds(mentioned.id) == %{"mention" => 1}

      {:ok, _} = Posts.update_post(post, %{body: "Hello everyone."})

      assert Repo.all(PostMention) == []
      assert kinds(mentioned.id) == %{}
    end

    test "deleting the post takes its mention events with it" do
      author = mentionable()
      mentioned = mentionable()
      post = create_post!(author, %{body: "Hello @#{mentioned.username}."})

      {:ok, _} = Posts.delete_post(post)

      assert Repo.all(PostMention) == []
      assert kinds(mentioned.id) == %{}
    end
  end

  describe "the derived feed" do
    test "carries the mention with the post that named the member" do
      author = mentionable(first_name: "Joe", last_name: "Armstrong")
      mentioned = mentionable()
      post = create_post!(author, %{body: "Over to @#{mentioned.username}."})

      assert [n] = notifications(mentioned.id)
      assert n.kind == "mention"
      assert n.post_id == post.id
      assert n.actor_name == "Joe Armstrong"
      assert n.actor_param == author.username
    end

    test "counts toward the unread badge and clears once read" do
      author = mentionable()
      mentioned = mentionable()
      create_post!(author, %{body: "Hi @#{mentioned.username}."})

      assert Activity.unread_notification_count(mentioned.id) == 1
      assert Activity.notifications_count(mentioned.id, ["mention"]) == 1

      # The read marker has to know about the kind, or its badge never clears.
      Activity.mark_notifications_read(mentioned.id)
      assert Activity.unread_notification_count(mentioned.id) == 0
    end

    test "is hidden from a member with a block either way to the author" do
      author = mentionable()
      mentioned = mentionable()
      {:ok, _} = Social.block_user(mentioned, author)

      Activity.subscribe(mentioned.id)
      create_post!(author, %{body: "Hi @#{mentioned.username}."})

      refute_receive {:new_notification, %{kind: "mention"}}, 50
      assert kinds(mentioned.id) == %{}
      assert Activity.unread_notification_count(mentioned.id) == 0
    end

    test "a mention in a post the member may not see stays hidden" do
      author = mentionable()
      mentioned = mentionable()

      create_post!(author, %{
        body: "Hi @#{mentioned.username}.",
        denials: [%{"denied_user_id" => mentioned.id}]
      })

      assert kinds(mentioned.id) == %{}
    end
  end

  describe "precedence: one event per post" do
    test "a direct answer that also names you stays a reply, never both" do
      me = mentionable()
      other = mentionable()
      root = create_post!(me, %{body: "root"})

      {:ok, _} = Posts.create_reply(other, root, %{body: "Good point, @#{me.username}!"})

      assert kinds(me.id) == %{"reply" => 1}
    end

    test "being named in a thread you write in beats the quieter thread event" do
      me = mentionable()
      other = mentionable()
      third = mentionable()
      root = create_post!(other, %{body: "root"})
      {:ok, mine} = Posts.create_reply(me, root, %{body: "mine"})

      # `third` answers `other`, not me — normally a "thread" event for me.
      # Naming me makes it a mention instead: same post, one row, stronger word.
      {:ok, _} = Posts.create_reply(third, mine, %{body: "what @#{me.username} said"})

      assert kinds(me.id) == %{"reply" => 1}

      {:ok, _} = Posts.create_reply(third, root, %{body: "also, @#{me.username}, look"})

      assert kinds(me.id) == %{"reply" => 1, "mention" => 1}
    end

    test "a thread reply that names nobody stays a thread event" do
      me = mentionable()
      other = mentionable()
      root = create_post!(other, %{body: "root"})
      {:ok, _} = Posts.create_reply(me, root, %{body: "mine"})

      {:ok, _} = Posts.create_reply(mentionable(), root, %{body: "no names here"})

      assert kinds(me.id) == %{"thread" => 1}
    end
  end
end
