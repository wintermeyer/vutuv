defmodule Vutuv.FeedPastFollowsTest do
  @moduledoc """
  Unfollowing stops the future without erasing the past (issue #1673).

  The feed reads the *current* follow set, so an unfollow used to take the
  followee's whole back catalogue with it. What a follow delivered while it was
  in force stays; what the author writes afterwards never arrives. The spans
  live in `past_follows` and are written at the two member-facing unfollow
  chokepoints.

  Every test here places its posts against an explicit span rather than trusting
  wall-clock ordering: `follows.inserted_at`, `past_follows.ended_at` and
  `posts.inserted_at` all have **second** precision, so a test that just
  follows, posts and unfollows puts all three in the same second and proves
  nothing about the boundaries.

  `async: false` because the organization half flips the global
  `:verify_organization_domains` flag, like every other page suite.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers
  import Vutuv.PostsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Posts.PostRepost
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Social.Follow
  alias Vutuv.Social.PastFollow

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp user(attrs \\ []), do: insert(:activated_user, attrs)

  defp ago(seconds), do: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -seconds)

  defp feed_ids(viewer), do: Posts.feed_page(viewer).entries |> Enum.map(& &1.post.id)

  # Follows and unfollows for real, then moves the recorded span to
  # `started_ago .. ended_ago` seconds before now, so the test can put posts
  # cleanly before, inside and after it.
  defp followed_between!(viewer, author, started_ago, ended_ago) do
    started_at = ago(started_ago)
    follow!(viewer, author)

    Repo.update_all(
      from(f in Follow, where: f.follower_id == ^viewer.id and f.followee_id == ^author.id),
      set: [inserted_at: started_at]
    )

    Social.unfollow!(viewer.id, Social.follow_id(viewer.id, author.id))

    # Scoped to the span this call just wrote (its start is the follow's), so a
    # test can lay down two spells of following without the second rewriting the
    # first.
    {1, nil} =
      Repo.update_all(
        from(w in PastFollow,
          where: w.follower_id == ^viewer.id and w.followee_id == ^author.id,
          where: w.started_at == ^started_at
        ),
        set: [ended_at: ago(ended_ago)]
      )

    :ok
  end

  describe "recording the span" do
    test "an unfollow records when the follow began and when it ended" do
      viewer = user()
      author = user()
      follow!(viewer, author)

      follow = Repo.get_by!(Follow, follower_id: viewer.id, followee_id: author.id)
      Social.unfollow!(viewer.id, follow.id)

      span = Repo.get_by!(PastFollow, follower_id: viewer.id, followee_id: author.id)
      assert span.started_at == follow.inserted_at
      assert NaiveDateTime.compare(span.ended_at, follow.inserted_at) != :lt
      refute Social.user_follows_user?(viewer.id, author.id)
    end

    test "a muted follow records nothing, so unfollowing cannot undo the mute" do
      viewer = user()
      noisy = user()
      follow!(viewer, noisy)
      post = backdate_post!(create_post!(noisy, %{body: "while followed"}), 60)

      follow_id = Social.follow_id(viewer.id, noisy.id)
      Social.toggle_follow_mute!(viewer.id, follow_id)
      refute post.id in feed_ids(viewer)

      Social.unfollow!(viewer.id, follow_id)

      assert Repo.get_by(PastFollow, follower_id: viewer.id, followee_id: noisy.id) == nil
      refute post.id in feed_ids(viewer)
    end

    test "following again after an unfollow leaves both spans standing" do
      viewer = user()
      author = user()

      followed_between!(viewer, author, 100, 80)
      followed_between!(viewer, author, 60, 40)

      spans = Repo.all(from(w in PastFollow, where: w.follower_id == ^viewer.id))
      assert length(spans) == 2

      first = backdate_post!(create_post!(author, %{body: "first spell"}), 90)
      between = backdate_post!(create_post!(author, %{body: "the gap"}), 70)
      second = backdate_post!(create_post!(author, %{body: "second spell"}), 50)

      ids = feed_ids(viewer)
      assert first.id in ids
      assert second.id in ids
      refute between.id in ids
    end
  end

  describe "what an ended follow still delivers" do
    test "posts from inside the span stay, newer and older ones do not" do
      viewer = user()
      author = user()

      before_follow = backdate_post!(create_post!(author, %{body: "before I followed"}), 120)
      delivered = backdate_post!(create_post!(author, %{body: "while I followed"}), 60)
      after_unfollow = create_post!(author, %{body: "after I left"})

      followed_between!(viewer, author, 90, 30)

      ids = feed_ids(viewer)
      assert delivered.id in ids
      refute before_follow.id in ids
      refute after_unfollow.id in ids
    end

    test "a followers-only post from inside the span drops out with the follow" do
      viewer = user()
      author = user()

      open = backdate_post!(create_post!(author, %{body: "for everyone"}), 60)

      private =
        backdate_post!(
          create_post!(author, %{
            body: "followers only",
            denials: [%{"wildcard" => "non_followers"}]
          }),
          60
        )

      followed_between!(viewer, author, 90, 30)

      ids = feed_ids(viewer)
      assert open.id in ids
      # The span is not a permission: `scope_visible/2` still asks whether the
      # viewer follows the author *now*, and they no longer do.
      refute private.id in ids
    end

    test "a reshare made during the span stays, stamped with the repost time" do
      viewer = user()
      resharer = user()
      stranger = user()

      post = backdate_post!(create_post!(stranger, %{body: "worth passing on"}), 200)
      :ok = Posts.repost_post(resharer, post)

      Repo.update_all(
        from(r in PostRepost, where: r.user_id == ^resharer.id and r.post_id == ^post.id),
        set: [inserted_at: ago(60)]
      )

      followed_between!(viewer, resharer, 90, 30)

      assert post.id in feed_ids(viewer)
    end

    test "a page's posts from inside the span stay after unfollowing the page" do
      {organization, owner} = active_organization()
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      viewer = user()

      {:ok, delivered} =
        Posts.create_organization_post(organization, owner, %{body: "while I followed"})

      delivered = backdate_post!(delivered, 60)

      {:ok, _follow} = Social.follow_organization(viewer, organization)

      Repo.update_all(
        from(f in Follow,
          where: f.follower_id == ^viewer.id and f.followee_organization_id == ^organization.id
        ),
        set: [inserted_at: ago(90)]
      )

      :ok = Social.unfollow_organization(viewer, organization)

      Repo.update_all(
        from(w in PastFollow,
          where: w.follower_id == ^viewer.id and w.followee_organization_id == ^organization.id
        ),
        set: [ended_at: ago(30)]
      )

      {:ok, later} = Posts.create_organization_post(organization, owner, %{body: "after I left"})

      ids = feed_ids(viewer)
      assert delivered.id in ids
      refute later.id in ids
    end
  end

  describe "what still clears the past out" do
    test "blocking removes the span, so the whole back catalogue goes" do
      viewer = user()
      author = user()

      delivered = backdate_post!(create_post!(author, %{body: "while I followed"}), 60)
      followed_between!(viewer, author, 90, 30)
      assert delivered.id in feed_ids(viewer)

      {:ok, _block} = Social.block_user(viewer, author)

      assert Repo.get_by(PastFollow, follower_id: viewer.id, followee_id: author.id) == nil
      refute delivered.id in feed_ids(viewer)
    end

    test "being blocked removes it too, in the other direction" do
      viewer = user()
      author = user()

      delivered = backdate_post!(create_post!(author, %{body: "while I followed"}), 60)
      followed_between!(viewer, author, 90, 30)

      {:ok, _block} = Social.block_user(author, viewer)

      refute delivered.id in feed_ids(viewer)
    end

    test "a block standing before the unfollow keeps the past out as well" do
      viewer = user()
      author = user()

      delivered = backdate_post!(create_post!(author, %{body: "while I followed"}), 60)
      followed_between!(viewer, author, 90, 30)
      # The span exists, and only the feed's own block filter stands between it
      # and the reader — the calibration for the filter added with issue #1673.
      Repo.insert!(%Vutuv.Social.Block{blocker_id: author.id, blocked_id: viewer.id})

      refute delivered.id in feed_ids(viewer)
    end
  end

  describe "one post, one entry" do
    # The tag source is "authors I do not follow", and an author whose follow
    # ended is one of those again — so a post inside a span can be reached from
    # two sources at once. Both dedupe layers already answer by **post** id
    # (`collapse_reposts/1` within a page, the feed LiveView's `shown_post_ids`
    # across pages), so nothing had to be added for this; the test locks the
    # promise in for the new path rather than guarding a new line of code.
    test "a followed tag does not deliver a spanned post a second time" do
      viewer = user()
      author = user()

      name = unique_tag_name("Elixir")
      tag = insert(:tag, name: name, slug: Vutuv.SlugHelpers.tagify(name))
      Vutuv.Tags.follow_tag(viewer, tag)

      post =
        author
        |> create_post!(%{body: "elixir news", tags: String.downcase(name)})
        |> backdate_post!(60)

      followed_between!(viewer, author, 90, 30)

      entries = Posts.feed_page(viewer).entries
      assert Enum.count(entries, &(&1.post.id == post.id)) == 1
    end
  end

  describe "reshared page posts and blocks" do
    test "a page's reshared post reaches a viewer who has blocked somebody" do
      {organization, owner} = active_organization()
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

      viewer = user()
      resharer = user()
      unrelated = user()
      follow!(viewer, resharer)

      {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "page news"})
      :ok = Posts.repost_post(resharer, post)

      assert post.id in feed_ids(viewer)

      # `p.user_id` is NULL on a page's post, and `NULL NOT IN (<non-empty>)` is
      # NULL — so one unrelated block used to empty the reshare of every page
      # post out of this feed. Calibrated against the un-fixed query, where the
      # assertion below fails.
      {:ok, _block} = Social.block_user(viewer, unrelated)

      assert post.id in feed_ids(viewer)
    end
  end
end
