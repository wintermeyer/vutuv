defmodule Vutuv.Posts.PendingPhotoVisibilityTest do
  @moduledoc """
  A photo still in the AI image scan holds back the **picture**, never the post
  (issue #1104).

  It used to hold the whole post, and the case that showed why that is the wrong
  unit is the last describe block here: somebody answers your post with a photo,
  you are told about the reply, and the reply is nowhere — not on the permalink,
  not in your notifications' quote, not anywhere you can look. The text was never
  what the scan is about.

  This is a visibility rule, so it is tested at the chokepoint on both sides:
  `visible_to?/2` (the single-post check) **and** `scope_visible/2` (the SQL twin
  every list goes through). The two must never disagree — a post that is hidden
  from a permalink but present in a feed query is the bug this file exists to
  prevent. Beside them sits the other half of the claim, which is what makes the
  change safe rather than merely friendlier: the unchecked picture itself is
  still nobody's to see, so every assertion that a post is readable is paired
  with one that its photo is not.
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

    test "the post is flagged as waiting, but not hidden", %{post: post} do
      assert post.images_pending?
      assert Posts.held_for_image_check?(post)
      refute Posts.moderation_hidden?(post)
    end

    test "everybody can read it — a member, an anonymous reader, the author", %{
      author: author,
      post: post,
      stranger: stranger
    } do
      for viewer <- [author, stranger, nil] do
        assert Posts.visible_to?(post, viewer)
        assert post.id in visible_ids(viewer)
      end
    end

    # The whole point of the gate, and the half that did not change: the text
    # goes out, the unjudged picture does not.
    test "the unchecked photo is still nobody's to see", %{post: post, images: [ok, pending]} do
      released = post |> Repo.preload(:images) |> Posts.released_images()

      assert Enum.map(released, & &1.id) == [ok.id]
      refute pending.id in Enum.map(released, & &1.id)
    end

    test "a follower's feed carries it right away", %{author: author, post: post} do
      follower = insert(:user, email_confirmed?: true)
      follow!(follower, author)

      assert post.id in feed_post_ids(follower)
    end

    test "so does the author's own", %{author: author, post: post} do
      assert post.id in feed_post_ids(author)
    end

    # The one thing that still takes a whole post out of circulation.
    test "the moderation freezer still does hide it", %{post: post, stranger: stranger} do
      frozen_at = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      frozen = post |> Ecto.Changeset.change(frozen_at: frozen_at) |> Repo.update!()

      assert Posts.moderation_hidden?(frozen)
      refute Posts.visible_to?(frozen, stranger)
      refute frozen.id in visible_ids(stranger)
    end
  end

  # Nobody waits for the scan any more, so there is no second fan-out: the post
  # is announced once, when it is written, to everybody it is addressed to.
  describe "the live fan-out" do
    setup do
      author = insert(:user, email_confirmed?: true)
      follower = insert(:user, email_confirmed?: true)
      follow!(follower, author)
      Vutuv.Activity.subscribe(follower.id)
      %{author: author, follower: follower}
    end

    test "a post whose photo is still being checked reaches the followers at once", %{
      author: author
    } do
      {post, _images} = photo_post!(author, ["pending"])

      assert_receive {:new_post, %{post_id: id}} when id == post.id
    end

    test "and is not announced a second time when the photo clears", %{author: author} do
      {post, [image]} = photo_post!(author, ["pending"])
      assert_receive {:new_post, %{post_id: id}} when id == post.id

      release(image, post)

      refute_receive {:new_post, _}, 50
    end

    test "an ordinary post still announces itself immediately", %{author: author} do
      post = create_post!(author, %{body: "no photos here"})

      assert_receive {:new_post, %{post_id: id}} when id == post.id
    end
  end

  describe "when the last photo settles" do
    test "the picture joins the post that was already public" do
      author = insert(:user, email_confirmed?: true)
      {post, [first, second]} = photo_post!(author, ["pending", "pending"])
      stranger = insert(:user)

      assert Posts.visible_to?(post, stranger)
      assert [] == post |> Repo.preload(:images) |> Posts.released_images()

      release(first, post)
      # One down, one to go: the post still says it is waiting for a photo.
      assert Repo.reload!(post).images_pending?

      release(second, post)

      settled = Repo.reload!(post)
      refute settled.images_pending?
      refute Posts.held_for_image_check?(settled)

      assert [first.id, second.id] ==
               settled |> Repo.preload(:images) |> Posts.released_images() |> Enum.map(& &1.id)
    end

    test "a rejected photo settles the post too — it is answered either way" do
      author = insert(:user, email_confirmed?: true)
      {post, [kept, rejected]} = photo_post!(author, ["approved", "pending"])

      # The reject path deletes the row, then settles the post.
      Repo.delete!(rejected)
      Posts.broadcast_images_settled(post.id)

      settled = Repo.reload!(post)
      refute settled.images_pending?
      assert Posts.visible_to?(settled, nil)

      assert [kept.id] ==
               settled |> Repo.preload(:images) |> Map.fetch!(:images) |> Enum.map(& &1.id)
    end

    test "the settle is claimed by exactly one caller" do
      author = insert(:user, email_confirmed?: true)
      {post, [image]} = photo_post!(author, ["pending"])

      image |> Ecto.Changeset.change(moderation: "approved") |> Repo.update!()

      # Two scans settling at the same moment: only the first write changes the
      # column, so only that one reports the settle.
      assert Posts.refresh_images_pending(post.id)
      refute Posts.refresh_images_pending(post.id)
    end
  end

  describe "editing" do
    test "attaching a fresh unchecked photo flags the post again, without hiding it" do
      author = insert(:user, email_confirmed?: true)
      {post, [approved]} = photo_post!(author, ["approved"])

      fresh = insert(:post_image, user: author, post_id: nil, moderation: "pending")

      {:ok, updated} =
        Posts.update_post(post, %{body: "Now with more.", image_ids: [approved.id, fresh.id]})

      assert updated.images_pending?
      assert Posts.visible_to?(Repo.reload!(post), nil)

      assert [approved.id] ==
               updated |> Repo.preload(:images) |> Posts.released_images() |> Enum.map(& &1.id)
    end

    test "removing the last unchecked photo clears the flag" do
      author = insert(:user, email_confirmed?: true)
      {post, [kept, pending]} = photo_post!(author, ["approved", "pending"])

      {:ok, updated} = Posts.update_post(post, %{body: "Dropped one.", image_ids: [kept.id]})

      refute updated.images_pending?
      refute Repo.get(Vutuv.Posts.PostImage, pending.id)
    end
  end

  # The report this change came from: the notification arrives, and the reply it
  # names has to be there when its recipient goes looking.
  describe "a reply carrying an unchecked photo" do
    test "is readable by the member it answers, and by everybody else" do
      author = insert(:user, email_confirmed?: true)
      replier = insert(:user, email_confirmed?: true)
      parent = create_post!(author, %{body: "the root"})

      image = insert(:post_image, user: replier, post_id: nil, moderation: "pending")
      {:ok, reply} = Posts.create_reply(replier, parent, %{body: "look", image_ids: [image.id]})

      reply = Repo.reload!(reply)
      assert reply.images_pending?

      for viewer <- [author, replier, insert(:user), nil] do
        assert Posts.visible_to?(reply, viewer)
        assert reply.id in visible_ids(viewer)
      end
    end

    test "shows up in the thread the notification links to" do
      author = insert(:user, email_confirmed?: true)
      replier = insert(:user, email_confirmed?: true)
      parent = create_post!(author, %{body: "the root"})

      image = insert(:post_image, user: replier, post_id: nil, moderation: "pending")
      {:ok, reply} = Posts.create_reply(replier, parent, %{body: "look", image_ids: [image.id]})

      %{posts: posts} = Posts.list_thread(parent, author)

      assert reply.id in Enum.map(posts, & &1.id)
    end
  end
end
