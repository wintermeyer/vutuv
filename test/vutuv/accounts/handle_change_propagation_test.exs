defmodule Vutuv.Accounts.HandleChangePropagationTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Accounts.HandleChangeNotification
  alias Vutuv.Activity
  alias Vutuv.Chat.Message
  alias Vutuv.Posts.Post
  alias Vutuv.Repo

  # `insert(:post/:message, ...)` bypasses the changeset, seeding a stored @old
  # mention directly — this suite tests propagation, not content creation.

  setup do
    # "oldname" exists while the mentions are seeded, so they are legitimate.
    %{victim: insert(:user, username: "oldname"), author: insert(:user, username: "writer")}
  end

  defp rename(victim), do: Accounts.update_username(victim, %{"username" => "newname"})

  test "rewrites @old to @new in another author's post", ctx do
    post = insert(:post, user: ctx.author, body: "great point @oldname!")
    assert {:ok, _} = rename(ctx.victim)
    assert Repo.get!(Post, post.id).body == "great point @newname!"
  end

  test "files one notification for the affected author with old/new/post_ids", ctx do
    post = insert(:post, user: ctx.author, body: "@oldname hello")
    assert {:ok, _} = rename(ctx.victim)

    notification = Repo.get_by!(HandleChangeNotification, recipient_id: ctx.author.id)
    assert notification.actor_id == ctx.victim.id
    assert notification.old_handle == "oldname"
    assert notification.new_handle == "newname"
    assert notification.post_ids == [post.id]
  end

  test "rewrites the renamer's own post but never notifies themselves", ctx do
    post = insert(:post, user: ctx.victim, body: "reminder @oldname")
    assert {:ok, _} = rename(ctx.victim)

    assert Repo.get!(Post, post.id).body == "reminder @newname"
    assert Repo.all(HandleChangeNotification) == []
  end

  test "groups several posts by one author into a single notification", ctx do
    p1 = insert(:post, user: ctx.author, body: "one @oldname")
    p2 = insert(:post, user: ctx.author, body: "two @oldname")
    assert {:ok, _} = rename(ctx.victim)

    notification = Repo.get_by!(HandleChangeNotification, recipient_id: ctx.author.id)
    assert Enum.sort(notification.post_ids) == Enum.sort([p1.id, p2.id])
  end

  test "rewrites @old mentions in a direct message too", ctx do
    sender = insert(:user)
    other = insert(:user)
    conversation = insert(:conversation, user_a: sender, user_b: other, initiator: sender)
    message = insert(:message, sender: sender, conversation: conversation, body: "ping @oldname")

    assert {:ok, _} = rename(ctx.victim)
    assert Repo.get!(Message, message.id).body == "ping @newname"
  end

  test "surfaces a handle_change item in the recipient's derived feed", ctx do
    post = insert(:post, user: ctx.author, body: "@oldname")
    assert {:ok, _} = rename(ctx.victim)

    page = Activity.notifications_page(ctx.author.id)
    item = Enum.find(page.entries, &(&1.kind == "handle_change"))

    assert item
    assert item.old_handle == "oldname"
    assert item.new_handle == "newname"
    assert item.post_ids == [post.id]
    assert item.actor_id == ctx.victim.id
    assert Activity.unread_notification_count(ctx.author.id) >= 1
  end

  test "pushes a live notification to the affected author", ctx do
    insert(:post, user: ctx.author, body: "@oldname")
    Activity.subscribe(ctx.author.id)

    assert {:ok, _} = rename(ctx.victim)

    assert_receive {:new_notification,
                    %{kind: "handle_change", old_handle: "oldname", new_handle: "newname"}}
  end

  test "blocks renaming to a handle already used in a post (anti-hijack)", ctx do
    insert(:post, body: "shout out to @wanted")
    assert {:error, changeset} = Accounts.update_username(ctx.victim, %{"username" => "wanted"})
    assert %{username: [message]} = errors_on(changeset)
    assert message =~ "post"
  end
end
