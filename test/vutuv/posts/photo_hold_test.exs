defmodule Vutuv.Posts.PhotoHoldTest do
  @moduledoc """
  A post waits for **all** of its photos to clear the AI image scan before it
  becomes public (issue #1104).

  This is a visibility rule, so it is tested at the chokepoint on both sides:
  `visible_to?/2` (the single-post check) **and** `scope_visible/2` (the SQL
  twin every list goes through). The two must never disagree — a post that is
  hidden from a permalink but present in a feed query is the bug this file
  exists to prevent.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo

  defp photo_post!(author, states) do
    images =
      for state <- states,
          do: insert(:post_image, user: author, post_id: nil, moderation: state)

    post = create_post!(author, %{body: "A set.", image_ids: Enum.map(images, & &1.id)})
    {Repo.reload!(post), images}
  end

  defp visible_ids(viewer) do
    Post |> Posts.scope_visible(viewer) |> Repo.all() |> Enum.map(& &1.id)
  end

  defp release(image, post) do
    image |> Ecto.Changeset.change(moderation: "approved") |> Repo.update!()
    Posts.broadcast_images_settled(post.id)
  end

  defp feed_post_ids(viewer),
    do: viewer |> Posts.feed_page() |> Map.fetch!(:entries) |> Enum.map(& &1.post.id)

  describe "while a photo is unchecked" do
    setup do
      author = insert(:user, email_confirmed?: true)
      {post, images} = photo_post!(author, ["approved", "pending"])
      %{author: author, post: post, images: images, stranger: insert(:user)}
    end

    test "the post is held", %{post: post} do
      assert post.images_pending?
      assert Posts.held_for_image_check?(post)
      assert Posts.moderation_hidden?(post)
    end

    test "its author still sees it, everywhere", %{author: author, post: post} do
      assert Posts.visible_to?(post, author)
      assert post.id in visible_ids(author)
    end

    test "nobody else does — not a member, not an anonymous reader", %{
      post: post,
      stranger: stranger
    } do
      refute Posts.visible_to?(post, stranger)
      refute Posts.visible_to?(post, nil)

      refute post.id in visible_ids(stranger)
      refute post.id in visible_ids(nil)
    end

    test "an admin can still open it, like any moderation-hidden post", %{post: post} do
      assert Posts.visible_to?(post, insert(:user, admin?: true))
    end

    test "a follower's feed does not carry it", %{author: author, post: post} do
      follower = insert(:user, email_confirmed?: true)
      follow!(follower, author)

      refute post.id in feed_post_ids(follower)
    end

    test "the author's own feed does carry it — they must see what they posted", %{
      author: author,
      post: post
    } do
      assert post.id in feed_post_ids(author)
    end
  end

  # The author has the card on screen from the moment they post; the followers
  # are told only once it is really there for them.
  describe "the live fan-out" do
    setup do
      author = insert(:user, email_confirmed?: true)
      follower = insert(:user, email_confirmed?: true)
      follow!(follower, author)
      Vutuv.Activity.subscribe(follower.id)
      %{author: author, follower: follower}
    end

    test "a held post announces itself to its author only", %{author: author} do
      Vutuv.Activity.subscribe(author.id)
      {post, _images} = photo_post!(author, ["pending"])

      assert_receive {:new_post, %{post_id: id}} when id == post.id
      refute_receive {:new_post, _}, 50
    end

    test "the followers hear about it when the last photo clears", %{author: author} do
      {post, [image]} = photo_post!(author, ["pending"])
      refute_receive {:new_post, _}, 50

      release(image, post)

      assert_receive {:new_post, %{post_id: id}} when id == post.id
    end

    test "an ordinary post still announces itself immediately", %{author: author} do
      post = create_post!(author, %{body: "no photos here"})

      assert_receive {:new_post, %{post_id: id}} when id == post.id
    end
  end

  describe "when the last photo clears" do
    test "the post becomes visible to everyone it was addressed to" do
      author = insert(:user, email_confirmed?: true)
      {post, [first, second]} = photo_post!(author, ["pending", "pending"])
      stranger = insert(:user)

      release(first, post)
      # One down, one to go: still held. The hold is all-or-nothing on purpose.
      refute Posts.visible_to?(Repo.reload!(post), stranger)

      release(second, post)

      released = Repo.reload!(post)
      refute released.images_pending?
      assert Posts.visible_to?(released, stranger)
      assert Posts.visible_to?(released, nil)
      assert released.id in visible_ids(nil)
    end

    test "it reaches its followers' feeds" do
      author = insert(:user, email_confirmed?: true)
      follower = insert(:user, email_confirmed?: true)
      follow!(follower, author)

      {post, [image]} = photo_post!(author, ["pending"])
      refute post.id in feed_post_ids(follower)

      release(image, post)

      assert post.id in feed_post_ids(follower)
    end

    test "a rejected photo releases the post too — it is settled either way" do
      author = insert(:user, email_confirmed?: true)
      {post, [kept, rejected]} = photo_post!(author, ["approved", "pending"])

      # The reject path deletes the row, then settles the post.
      Repo.delete!(rejected)
      Posts.broadcast_images_settled(post.id)

      released = Repo.reload!(post)
      refute released.images_pending?
      assert Posts.visible_to?(released, nil)

      assert [kept.id] ==
               released |> Repo.preload(:images) |> Map.fetch!(:images) |> Enum.map(& &1.id)
    end

    test "the release is claimed by exactly one caller, so a post fans out once" do
      author = insert(:user, email_confirmed?: true)
      {post, [image]} = photo_post!(author, ["pending"])

      image |> Ecto.Changeset.change(moderation: "approved") |> Repo.update!()

      # Two scans settling at the same moment: only the first write changes the
      # column, so only that one reports the release.
      assert Posts.refresh_images_pending(post.id)
      refute Posts.refresh_images_pending(post.id)
    end
  end

  describe "posts that never wait" do
    test "a text-only post is public immediately" do
      author = insert(:user, email_confirmed?: true)
      post = create_post!(author, %{body: "Just words."})

      refute post.images_pending?
      assert Posts.visible_to?(post, nil)
    end

    test "a post whose photos are already approved is public immediately" do
      author = insert(:user, email_confirmed?: true)
      {post, _images} = photo_post!(author, ["approved", "approved"])

      refute post.images_pending?
      assert Posts.visible_to?(post, nil)
    end
  end

  describe "editing" do
    test "attaching a fresh unchecked photo holds the post again" do
      author = insert(:user, email_confirmed?: true)
      {post, [approved]} = photo_post!(author, ["approved"])
      assert Posts.visible_to?(post, nil)

      fresh = insert(:post_image, user: author, post_id: nil, moderation: "pending")

      {:ok, updated} =
        Posts.update_post(post, %{body: "Now with more.", image_ids: [approved.id, fresh.id]})

      assert updated.images_pending?
      refute Posts.visible_to?(Repo.reload!(post), nil)
    end

    test "removing the last unchecked photo releases it" do
      author = insert(:user, email_confirmed?: true)
      {post, [kept, pending]} = photo_post!(author, ["approved", "pending"])
      refute Posts.visible_to?(post, nil)

      {:ok, updated} = Posts.update_post(post, %{body: "Dropped one.", image_ids: [kept.id]})

      refute updated.images_pending?
      assert Posts.visible_to?(Repo.reload!(post), nil)
      refute Repo.get(Vutuv.Posts.PostImage, pending.id)
    end
  end

  describe "replies" do
    test "a reply carrying an unchecked photo is held like any other post" do
      author = insert(:user, email_confirmed?: true)
      replier = insert(:user, email_confirmed?: true)
      parent = create_post!(author, %{body: "the root"})

      image = insert(:post_image, user: replier, post_id: nil, moderation: "pending")
      {:ok, reply} = Posts.create_reply(replier, parent, %{body: "look", image_ids: [image.id]})

      reply = Repo.reload!(reply)
      assert reply.images_pending?
      refute Posts.visible_to?(reply, nil)
      assert Posts.visible_to?(reply, replier)
    end
  end
end
