defmodule Vutuv.PostsTest do
  use Vutuv.DataCase, async: true
  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostDenial
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostReply
  alias Vutuv.Posts.PostRepost
  alias Vutuv.Posts.PostTag

  # Feed authors must be activated (consistent with follower counts etc.), so
  # the default test user is.
  defp user(attrs \\ []), do: insert(:activated_user, attrs)

  # Timeline ordering ties at second precision; shift a post into the past so
  # order assertions stay deterministic.
  defp backdate_post!(post, seconds) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -seconds)
    Repo.update_all(from(p in Post, where: p.id == ^post.id), set: [inserted_at: at])
    %{post | inserted_at: at}
  end

  # Repost order ties at second precision too; shift `reposter`'s repost of
  # `post` into the past so "newest reposter" assertions stay deterministic.
  defp backdate_repost!(reposter, post, seconds) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -seconds)

    Repo.update_all(
      from(r in PostRepost, where: r.user_id == ^reposter.id and r.post_id == ^post.id),
      set: [inserted_at: at]
    )
  end

  describe "create_post/2" do
    test "creates a public post stamped with today's Berlin date" do
      author = user()

      assert {:ok, %Post{} = post} = Posts.create_post(author, %{body: "Hello **world**"})
      assert post.body == "Hello **world**"
      # The archive coordinate is the German calendar day, like every other
      # user-facing day in the app — not the UTC day, which lags Berlin by
      # 1-2 hours around midnight.
      assert post.published_on == Vutuv.BerlinTime.today()
      assert post.denials == []
      assert post.user.id == author.id
    end

    test "trims the body" do
      assert create_post!(user(), %{body: "  hi  \n"}).body == "hi"
    end

    test "rejects a body over the length limit" do
      body = String.duplicate("x", Post.max_body_length() + 1)
      assert {:error, %Ecto.Changeset{} = changeset} = Posts.create_post(user(), %{body: body})
      assert %{body: [_]} = errors_on(changeset)
    end

    test "rejects an empty post (no body, no images)" do
      assert {:error, %Ecto.Changeset{} = changeset} = Posts.create_post(user(), %{body: "   "})
      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts a body that embeds an own-upload image reference" do
      body = "hi ![x](/post_images/t/large.avif)"
      assert {:ok, post} = Posts.create_post(user(), %{body: body})
      assert post.body == body
    end

    test "accepts an alignment fragment on an inline image reference" do
      body = "hi ![x](/post_images/t/feed.avif#left)"
      assert {:ok, post} = Posts.create_post(user(), %{body: body})
      assert post.body == body
    end

    test "rejects a body that embeds a remote (hotlinked) image" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Posts.create_post(user(), %{body: "hi ![x](https://evil.example/pixel.png)"})

      assert "may only embed images uploaded to this post" in errors_on(changeset).body
    end

    test "rejects an inline reference with an unknown alignment fragment" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Posts.create_post(user(), %{body: "hi ![x](/post_images/t/feed.avif#sparkle)"})

      assert "may only embed images uploaded to this post" in errors_on(changeset).body
    end

    test "allows remote image Markdown shown inside a code sample" do
      body = "```\n![x](https://evil.example/pixel.png)\n```"
      assert {:ok, post} = Posts.create_post(user(), %{body: body})
      assert post.body == body
    end

    test "allows an empty body when images are attached" do
      author = user()
      image = insert(:post_image, user: author, post: nil)

      assert {:ok, post} = Posts.create_post(author, %{body: "", image_ids: [image.id]})
      assert [attached] = post.images
      assert attached.id == image.id
      assert attached.position == 0
    end

    test "attaches pending images in the given order" do
      author = user()
      [a, b, c] = for _ <- 1..3, do: insert(:post_image, user: author, post: nil)

      post = create_post!(author, %{body: "pics", image_ids: [c.id, a.id, b.id]})

      assert Enum.map(post.images, & &1.id) == [c.id, a.id, b.id]
      assert Enum.map(post.images, & &1.position) == [0, 1, 2]
    end

    test "rejects attaching someone else's image" do
      author = user()
      foreign = insert(:post_image, user: user(), post: nil)

      assert {:error, :invalid_images} =
               Posts.create_post(author, %{body: "x", image_ids: [foreign.id]})

      # Nothing was inserted.
      refute Repo.exists?(from(p in Post, where: p.user_id == ^author.id))
    end

    test "rejects attaching an image that already belongs to a post" do
      author = user()
      old_post = create_post!(author, %{body: "old"})
      taken = insert(:post_image, user: author, post: old_post)

      assert {:error, :invalid_images} =
               Posts.create_post(author, %{body: "x", image_ids: [taken.id]})
    end

    test "rejects more images than the limit" do
      author = user()

      images =
        for _ <- 1..(Posts.max_images_per_post() + 1) do
          insert(:post_image, user: author, post: nil)
        end

      assert {:error, :too_many_images} =
               Posts.create_post(author, %{body: "x", image_ids: Enum.map(images, & &1.id)})
    end

    test "creates tags from a comma- or space-separated list, reusing tags case-insensitively" do
      existing = insert(:tag, name: "Elixir", slug: "elixir")

      # An unquoted comma and space both still split, so "Phoenix Ecto" is two
      # tags; a quoted phrase stays one multi-word tag.
      post = create_post!(user(), %{body: "tagged", tags: "elixir, Phoenix Ecto"})

      tag_names = post.tags |> Enum.map(& &1.name) |> Enum.sort()
      assert tag_names == ["Ecto", "Elixir", "Phoenix"]
      assert Enum.any?(post.tags, &(&1.id == existing.id))
    end

    test "keeps a quoted phrase as one multi-word post tag" do
      post = create_post!(user(), %{body: "tagged", tags: ~s(Elixir, "Ruby on Rails")})

      tag_names = post.tags |> Enum.map(& &1.name) |> Enum.sort()
      assert tag_names == ["Elixir", "Ruby on Rails"]
    end

    test "strips a leading # from post tags and reuses the bare tag" do
      existing = insert(:tag, name: "Elixir", slug: "elixir")

      # A member types the hashtag form in the composer; it stores the bare tags
      # and links #Elixir to the existing Elixir tag rather than a # duplicate.
      post = create_post!(user(), %{body: "tagged", tags: "#Elixir #phoenix"})

      tag_names = post.tags |> Enum.map(& &1.name) |> Enum.sort()
      assert tag_names == ["Elixir", "phoenix"]
      assert Enum.any?(post.tags, &(&1.id == existing.id))
    end

    test "keeps at most #{Vutuv.Posts.max_tags_per_post()} tags, in input order" do
      tags = Enum.map_join(1..7, ", ", &"tag-number-#{&1}")

      post = create_post!(user(), %{body: "tagged", tags: tags})

      assert length(post.tags) == Posts.max_tags_per_post()

      kept = post.tags |> Enum.map(& &1.name) |> Enum.sort()
      expected = Enum.map(1..Posts.max_tags_per_post(), &"tag-number-#{&1}") |> Enum.sort()
      assert kept == expected
    end

    test "stores wildcard and per-user denials" do
      author = user()
      denied = user()

      post =
        create_post!(author, %{
          body: "restricted",
          denials: [
            %{"wildcard" => "non_followers"},
            %{"denied_user_id" => denied.id}
          ]
        })

      assert length(post.denials) == 2
      assert Enum.any?(post.denials, &(&1.wildcard == "non_followers"))
      assert Enum.any?(post.denials, &(&1.denied_user_id == denied.id))
    end

    test "rejects denying yourself and unknown wildcards" do
      author = user()

      assert {:error, :invalid_denials} =
               Posts.create_post(author, %{body: "x", denials: [%{"denied_user_id" => author.id}]})

      assert {:error, :invalid_denials} =
               Posts.create_post(author, %{body: "x", denials: [%{"wildcard" => "nonsense"}]})
    end

    test "broadcasts the new post to followers and the author" do
      author = user()
      follower = user()
      follow!(follower, author)

      Vutuv.Activity.subscribe(follower.id)
      Vutuv.Activity.subscribe(author.id)

      post = create_post!(author, %{body: "news"})
      post_id = post.id
      author_id = author.id

      assert_receive {:new_post, %{post_id: ^post_id, author_id: ^author_id}}
      assert_receive {:new_post, %{post_id: ^post_id, author_id: ^author_id}}
    end
  end

  describe "visible_to?/2" do
    test "a post without denials is visible to everyone" do
      author = user()
      post = create_post!(author, %{body: "public"})

      assert Posts.visible_to?(post, nil)
      assert Posts.visible_to?(post, user())
      assert Posts.visible_to?(post, author)
    end

    test "wildcard everyone: only the author" do
      author = user()
      follower = user()
      follow!(follower, author)
      post = create_post!(author, %{body: "x", denials: [%{"wildcard" => "everyone"}]})

      assert Posts.visible_to?(post, author)
      refute Posts.visible_to?(post, follower)
      refute Posts.visible_to?(post, user())
      refute Posts.visible_to?(post, nil)
    end

    test "wildcard non_followers: only people who follow the author" do
      author = user()
      follower = user()
      followee = user()
      follow!(follower, author)
      follow!(author, followee)

      post = create_post!(author, %{body: "x", denials: [%{"wildcard" => "non_followers"}]})

      assert Posts.visible_to?(post, author)
      assert Posts.visible_to?(post, follower)
      refute Posts.visible_to?(post, followee)
      refute Posts.visible_to?(post, user())
      refute Posts.visible_to?(post, nil)
    end

    test "wildcard non_followees: only people the author follows" do
      author = user()
      followee = user()
      follower = user()
      follow!(author, followee)
      follow!(follower, author)

      post = create_post!(author, %{body: "x", denials: [%{"wildcard" => "non_followees"}]})

      assert Posts.visible_to?(post, author)
      assert Posts.visible_to?(post, followee)
      refute Posts.visible_to?(post, follower)
      refute Posts.visible_to?(post, nil)
    end

    test "wildcard non_connections: only the author's mutual follows (vernetzt)" do
      author = user()
      connected = user()
      follower = user()
      connect!(author, connected)
      # A mere one-way follower (not mutual) must not get in.
      follow!(follower, author)

      post = create_post!(author, %{body: "x", denials: [%{"wildcard" => "non_connections"}]})

      assert Posts.visible_to?(post, author)
      assert Posts.visible_to?(post, connected)
      refute Posts.visible_to?(post, follower)
      refute Posts.visible_to?(post, user())
      refute Posts.visible_to?(post, nil)
    end

    test "a one-way follow does not unlock a connections-only post" do
      author = user()
      follower = user()
      # follower follows author, but author does not follow back → not vernetzt.
      follow!(follower, author)

      post = create_post!(author, %{body: "x", denials: [%{"wildcard" => "non_connections"}]})

      refute Posts.visible_to?(post, follower)
    end

    test "a muted mutual follow still unlocks a connections-only post" do
      # Mute only affects the muter's feed, not post visibility: a vernetzt
      # member who muted the author still counts as connected.
      author = user()
      connected = user()
      connect!(author, connected)
      fid = Vutuv.Social.follow_id(connected.id, author.id)
      Vutuv.Social.toggle_follow_mute!(connected.id, fid)

      post = create_post!(author, %{body: "x", denials: [%{"wildcard" => "non_connections"}]})

      assert Posts.visible_to?(post, connected)
    end

    test "scope_visible agrees with visible_to? for non_connections (list path)" do
      author = user()
      connected = user()
      stranger = user()
      connect!(author, connected)
      create_post!(author, %{body: "x", denials: [%{"wildcard" => "non_connections"}]})

      assert Posts.count_author_posts(author, connected) == 1
      assert Posts.count_author_posts(author, stranger) == 0
      assert Posts.count_author_posts(author, nil) == 0
    end

    test "wildcard logged_out: any member, but no anonymous visitors" do
      author = user()
      post = create_post!(author, %{body: "x", denials: [%{"wildcard" => "logged_out"}]})

      assert Posts.visible_to?(post, author)
      assert Posts.visible_to?(post, user())
      refute Posts.visible_to?(post, nil)
    end

    test "per-user denial: hides from exactly that person" do
      author = user()
      denied = user()
      post = create_post!(author, %{body: "x", denials: [%{"denied_user_id" => denied.id}]})

      assert Posts.visible_to?(post, author)
      assert Posts.visible_to?(post, user())
      refute Posts.visible_to?(post, denied)
      refute Posts.visible_to?(post, nil)
    end

    test "denials are a union: matching any one of them denies" do
      author = user()
      denied = user()
      follower_outside = user()
      follow!(follower_outside, author)

      post =
        create_post!(author, %{
          body: "x",
          denials: [%{"wildcard" => "non_followers"}, %{"denied_user_id" => denied.id}]
        })

      # The outside follower matches neither denial; the named user matches the
      # per-user denial; a stranger matches non_followers.
      assert Posts.visible_to?(post, follower_outside)
      refute Posts.visible_to?(post, denied)
      refute Posts.visible_to?(post, user())
    end
  end

  describe "profile_posts/3 (the SQL visibility scope)" do
    test "matches visible_to?/2 across the denial matrix" do
      author = user()
      follower = user()
      followee = user()
      denied = user()
      stranger = user()
      follow!(follower, author)
      follow!(author, followee)

      public = create_post!(author, %{body: "public"})
      only_me = create_post!(author, %{body: "me", denials: [%{"wildcard" => "everyone"}]})

      followers_only =
        create_post!(author, %{body: "f", denials: [%{"wildcard" => "non_followers"}]})

      followees_only =
        create_post!(author, %{body: "g", denials: [%{"wildcard" => "non_followees"}]})

      members_only = create_post!(author, %{body: "m", denials: [%{"wildcard" => "logged_out"}]})
      not_you = create_post!(author, %{body: "n", denials: [%{"denied_user_id" => denied.id}]})

      all = [public, only_me, followers_only, followees_only, members_only, not_you]

      for viewer <- [nil, author, follower, followee, denied, stranger] do
        expected =
          all
          |> Enum.filter(&Posts.visible_to?(&1, viewer))
          |> Enum.map(& &1.id)
          |> Enum.sort()

        actual =
          author
          |> Posts.profile_posts(viewer, limit: 100)
          |> Enum.map(& &1.post.id)
          |> Enum.sort()

        assert actual == expected, "scope mismatch for viewer #{inspect(viewer && viewer.id)}"
      end
    end

    test "returns newest first and respects the limit" do
      author = user()
      [_one, two, three] = for n <- 1..3, do: create_post!(author, %{body: "post #{n}"})

      assert [latest, previous] = Posts.profile_posts(author, nil, limit: 2)
      assert latest.post.id == three.id
      assert previous.post.id == two.id
    end

    test "includes the author's reposts, stamped with the repost time" do
      author = user()
      original_author = user()
      original = create_post!(original_author, %{body: "carried"})
      own = create_post!(author, %{body: "own"})
      backdate_post!(own, 60)
      :ok = Posts.repost_post(author, original)

      assert [repost_entry, own_entry] = Posts.profile_posts(author, nil, limit: 10)
      assert repost_entry.post.id == original.id
      assert repost_entry.reposted_by.id == author.id
      assert String.starts_with?(repost_entry.id, "repost-")
      assert own_entry.post.id == own.id
      assert own_entry.reposted_by == nil

      assert Posts.count_author_posts(author, nil) == 2
    end

    test "a self-reply nests the parent inline and doesn't show it standalone" do
      author = user()
      parent = create_post!(author, %{body: "original"})
      {:ok, reply} = Posts.create_reply(author, parent, %{body: "following up"})

      ids = Posts.profile_posts(author, nil, limit: 10) |> Enum.map(& &1.id)
      assert ids == ["post-#{reply.id}"]
    end
  end

  describe "feed_page/2" do
    test "shows own and followees' posts, not strangers'" do
      viewer = user()
      friend = user()
      stranger = user()
      follow!(viewer, friend)

      mine = create_post!(viewer, %{body: "mine"})
      theirs = create_post!(friend, %{body: "theirs"})
      create_post!(stranger, %{body: "unrelated"})

      %{entries: entries} = Posts.feed_page(viewer)
      assert Enum.map(entries, & &1.post.id) |> Enum.sort() == Enum.sort([mine.id, theirs.id])
    end

    test "a muted follow drops the followee's posts from the feed, follow intact" do
      viewer = user()
      noisy = user()
      follow!(viewer, noisy)

      before = create_post!(noisy, %{body: "before mute"})
      %{entries: entries} = Posts.feed_page(viewer)
      assert before.id in Enum.map(entries, & &1.post.id)

      fid = Vutuv.Social.follow_id(viewer.id, noisy.id)
      Vutuv.Social.toggle_follow_mute!(viewer.id, fid)

      after_mute = create_post!(noisy, %{body: "after mute"})
      ids = Posts.feed_page(viewer).entries |> Enum.map(& &1.post.id)
      refute after_mute.id in ids
      refute before.id in ids
      # Muting only changes the feed; the follow survives.
      assert Vutuv.Social.user_follows_user?(viewer.id, noisy.id)

      # Unmuting brings the posts back.
      Vutuv.Social.toggle_follow_mute!(viewer.id, fid)
      ids = Posts.feed_page(viewer).entries |> Enum.map(& &1.post.id)
      assert after_mute.id in ids
      assert before.id in ids
    end

    test "applies denials inside the feed query" do
      viewer = user()
      friend = user()
      aloof = user()
      follow!(viewer, friend)
      # aloof does NOT follow viewer back, so the non_followees denial hides it.
      follow!(viewer, aloof)

      create_post!(friend, %{body: "hidden", denials: [%{"denied_user_id" => viewer.id}]})
      create_post!(aloof, %{body: "circle", denials: [%{"wildcard" => "non_followees"}]})

      visible =
        create_post!(friend, %{body: "visible", denials: [%{"wildcard" => "non_followers"}]})

      %{entries: entries} = Posts.feed_page(viewer)
      assert Enum.map(entries, & &1.post.id) == [visible.id]
    end

    test "hides posts from unactivated authors but always shows own" do
      viewer = user(email_confirmed?: false)
      unactivated = user(email_confirmed?: false)
      follow!(viewer, unactivated)

      mine = create_post!(viewer, %{body: "mine"})
      create_post!(unactivated, %{body: "ghost"})

      %{entries: entries} = Posts.feed_page(viewer)
      assert Enum.map(entries, & &1.post.id) == [mine.id]
    end

    test "paginates with a cursor, newest first" do
      viewer = user()
      posts = for n <- 1..5, do: create_post!(viewer, %{body: "post #{n}"})
      expected_ids = posts |> Enum.map(& &1.id) |> Enum.reverse()

      page1 = Posts.feed_page(viewer, limit: 2)
      assert page1.more?
      page2 = Posts.feed_page(viewer, limit: 2, cursor: page1.next_cursor)
      assert page2.more?
      page3 = Posts.feed_page(viewer, limit: 2, cursor: page2.next_cursor)
      refute page3.more?
      assert page3.next_cursor == nil

      walked = Enum.map(page1.entries ++ page2.entries ++ page3.entries, & &1.post.id)
      assert walked == expected_ids
    end

    test "carries followees' reposts into the feed, stamped with the repost time" do
      viewer = user()
      friend = user()
      stranger = user()
      follow!(viewer, friend)

      old = create_post!(stranger, %{body: "old but gold"})
      backdate_post!(old, 120)
      mine = create_post!(viewer, %{body: "mine"})
      backdate_post!(mine, 60)
      :ok = Posts.repost_post(friend, old)

      %{entries: [repost_entry, own_entry]} = Posts.feed_page(viewer)

      assert repost_entry.post.id == old.id
      assert repost_entry.reposted_by.id == friend.id
      assert own_entry.post.id == mine.id
      assert own_entry.reposted_by == nil
    end

    test "ignores reposts by strangers and by unactivated reposters" do
      viewer = user()
      unactivated = user(email_confirmed?: false)
      stranger = user()
      follow!(viewer, unactivated)

      post = create_post!(user(), %{body: "x"})
      :ok = Posts.repost_post(unactivated, post)
      :ok = Posts.repost_post(stranger, post)

      assert %{entries: []} = Posts.feed_page(viewer)
    end

    test "many reposts of one post collapse into a single entry with the reposter roster" do
      viewer = user()
      author = user()
      early = user()
      late = user()
      follow!(viewer, early)
      follow!(viewer, late)

      post = create_post!(author, %{body: "much shared"})
      backdate_post!(post, 600)
      :ok = Posts.repost_post(early, post)
      backdate_repost!(early, post, 300)
      :ok = Posts.repost_post(late, post)

      assert %{entries: [entry]} = Posts.feed_page(viewer)
      assert entry.post.id == post.id
      # The newest repost carries the entry; every followed reposter joins the
      # roster, newest first.
      assert entry.reposted_by.id == late.id
      assert Enum.map(entry.reposters, & &1.id) == [late.id, early.id]
    end

    test "a repost resurfaces a followed author's post once, at the repost position" do
      viewer = user()
      author = user()
      friend = user()
      follow!(viewer, author)
      follow!(viewer, friend)

      post = create_post!(author, %{body: "original words"})
      backdate_post!(post, 600)
      mine = create_post!(viewer, %{body: "mine"})
      backdate_post!(mine, 300)
      :ok = Posts.repost_post(friend, post)

      # One entry for the reposted post — the repost carries it (that's why it
      # sits on top), the standalone original row is gone.
      %{entries: entries} = Posts.feed_page(viewer)
      assert Enum.map(entries, & &1.post.id) == [post.id, mine.id]

      [entry, _mine] = entries
      assert entry.reposted_by.id == friend.id
      assert String.starts_with?(entry.id, "repost-")
    end

    test "the roster holds only followed reposters and yourself, not strangers" do
      viewer = user()
      author = user()
      friend = user()
      stranger = user()
      follow!(viewer, friend)

      post = create_post!(author, %{body: "roster"})
      backdate_post!(post, 600)
      :ok = Posts.repost_post(stranger, post)
      backdate_repost!(stranger, post, 300)
      :ok = Posts.repost_post(friend, post)
      backdate_repost!(friend, post, 120)
      :ok = Posts.repost_post(viewer, post)

      assert %{entries: [entry]} = Posts.feed_page(viewer)
      # The stranger reposted most recently of the three but is invisible here:
      # the roster explains why the post is in *this* feed, so it holds only
      # followed reposters and the viewer, newest first.
      assert Enum.map(entry.reposters, & &1.id) == [viewer.id, friend.id]
      assert entry.reposted_by.id == viewer.id
    end

    test "plain post entries carry an empty roster" do
      viewer = user()
      create_post!(viewer, %{body: "no reposts"})

      assert %{entries: [entry]} = Posts.feed_page(viewer)
      assert entry.reposters == []
      assert entry.reposted_by == nil
    end

    test "a muted follow's repost neither surfaces the post nor joins the roster" do
      viewer = user()
      author = user()
      noisy = user()
      friend = user()
      follow!(viewer, noisy)
      follow!(viewer, friend)

      post = create_post!(author, %{body: "muted path"})
      backdate_post!(post, 600)
      :ok = Posts.repost_post(noisy, post)
      backdate_repost!(noisy, post, 300)
      :ok = Posts.repost_post(friend, post)

      fid = Vutuv.Social.follow_id(viewer.id, noisy.id)
      Vutuv.Social.toggle_follow_mute!(viewer.id, fid)

      assert %{entries: [entry]} = Posts.feed_page(viewer)
      assert Enum.map(entry.reposters, & &1.id) == [friend.id]
    end

    test "a repost of a post shown inside a conversation drops for the page" do
      viewer = user()
      author = user()
      replier = user()
      reposter = user()
      follow!(viewer, author)
      follow!(viewer, replier)
      follow!(viewer, reposter)

      parent = create_post!(author, %{body: "thread root"})
      backdate_post!(parent, 600)
      {:ok, reply} = Posts.create_reply(replier, parent, %{body: "thread reply"})
      backdate_post!(reply, 300)
      :ok = Posts.repost_post(reposter, parent)

      # The conversation wins: the parent already renders as a full card nested
      # inside the thread, so a standalone repost card would show it twice.
      assert %{entries: [entry]} = Posts.feed_page(viewer)
      assert entry.post.id == reply.id
      assert Enum.map(entry.ancestors, & &1.id) == [parent.id]
    end

    test "a reposted reply nests its parent instead of also showing it standalone" do
      viewer = user()
      author = user()
      replier = user()
      reposter = user()
      follow!(viewer, author)
      follow!(viewer, reposter)

      parent = create_post!(author, %{body: "parent words"})
      backdate_post!(parent, 600)
      {:ok, reply} = Posts.create_reply(replier, parent, %{body: "the reply"})
      backdate_post!(reply, 300)
      :ok = Posts.repost_post(reposter, reply)

      # The reposted reply nests the followed author's parent as its context
      # card, so the parent's own standalone row is a duplicate and drops.
      assert %{entries: [entry]} = Posts.feed_page(viewer)
      assert entry.post.id == reply.id
      assert entry.reposted_by.id == reposter.id
      assert Enum.map(entry.ancestors, & &1.id) == [parent.id]
    end

    test "paginates a mixed posts-and-reposts timeline without gaps or repeats" do
      viewer = user()
      friend = user()
      follow!(viewer, friend)

      for n <- 1..3, do: create_post!(viewer, %{body: "post #{n}"})

      for _ <- 1..3 do
        post = create_post!(user(), %{body: "elsewhere"})
        :ok = Posts.repost_post(friend, post)
      end

      page1 = Posts.feed_page(viewer, limit: 4)
      assert page1.more?
      page2 = Posts.feed_page(viewer, limit: 4, cursor: page1.next_cursor)
      refute page2.more?

      walked = Enum.map(page1.entries ++ page2.entries, & &1.id)
      assert length(walked) == 6
      assert Enum.uniq(walked) == walked
    end

    test "when you reply to a followee's post, the parent isn't shown twice" do
      # The reply already renders the parent inline (the threaded card), so a
      # separate standalone entry for that parent is a visible duplicate: the
      # feed showed the followed author's post both on its own and nested under
      # the reply. Only the threaded reply should remain.
      viewer = user()
      author = user()
      follow!(viewer, author)

      parent = create_post!(author, %{body: "original"})
      {:ok, reply} = Posts.create_reply(viewer, parent, %{body: "an answer"})

      ids = Posts.feed_page(viewer).entries |> Enum.map(& &1.id)
      assert ids == ["post-#{reply.id}"]
      refute "post-#{parent.id}" in ids
    end

    test "a followee's reply to another followee's post hides the standalone parent" do
      viewer = user()
      author = user()
      replier = user()
      follow!(viewer, author)
      follow!(viewer, replier)

      parent = create_post!(author, %{body: "original"})
      {:ok, reply} = Posts.create_reply(replier, parent, %{body: "an answer"})

      ids = Posts.feed_page(viewer).entries |> Enum.map(& &1.id)
      assert ids == ["post-#{reply.id}"]
    end

    test "a lone reply whose parent isn't in the feed still shows (parent nested inline)" do
      viewer = user()
      parent = create_post!(user(), %{body: "original"})
      {:ok, reply} = Posts.create_reply(viewer, parent, %{body: "answer"})

      entries = Posts.feed_page(viewer).entries
      assert Enum.map(entries, & &1.id) == ["post-#{reply.id}"]
    end

    test "a branching thread (a post answered twice) collapses into one entry" do
      # A reply nests the whole conversation it answers as full cards. When one
      # post has *two* replies that both land on the page, each branch used to
      # carry the shared ancestors, so the entire thread rendered once per branch
      # — it appeared twice in the feed (the real report: root -> "Und?" ->
      # "Kommt an", the last answered by BOTH an Oliver reply and a Stefan reply).
      # The whole conversation must collapse into a single feed entry.
      viewer = user()
      other = user()
      follow!(viewer, other)

      root = create_post!(other, %{body: "root"})
      {:ok, mid} = Posts.create_reply(viewer, root, %{body: "und?"})
      {:ok, branch} = Posts.create_reply(other, mid, %{body: "kommt an"})
      # `branch` is answered twice — once by the followee, once by the viewer.
      {:ok, leaf_a} = Posts.create_reply(other, branch, %{body: "ausgehende replies"})
      {:ok, leaf_b} = Posts.create_reply(viewer, branch, %{body: "blick auf issue 843"})

      assert [entry] = Posts.feed_page(viewer).entries

      # Every post of the thread appears exactly once (its ancestors plus the
      # leaf), no post repeated across branches.
      shown = Enum.map(entry.ancestors, & &1.id) ++ [entry.post.id]
      assert Enum.sort(shown) == Enum.sort([root.id, mid.id, branch.id, leaf_a.id, leaf_b.id])
      assert Enum.uniq(shown) == shown
    end
  end

  describe "discover_posts/2" do
    test "returns a same-language stranger's public post with the author preloaded" do
      viewer = user(locale: "de")
      author = user(locale: "de")
      post = create_post!(author, %{body: "entdecke mich"})

      assert [found] = Posts.discover_posts(viewer)
      assert found.id == post.id
      assert found.user.id == author.id
    end

    test "excludes authors the viewer follows, including muted follows" do
      viewer = user()
      followed = user()
      muted = user()
      follow!(viewer, followed)
      follow!(viewer, muted)
      fid = Vutuv.Social.follow_id(viewer.id, muted.id)
      Vutuv.Social.toggle_follow_mute!(viewer.id, fid)

      create_post!(followed, %{body: "already following"})
      create_post!(muted, %{body: "muted but still followed"})
      fresh = create_post!(user(), %{body: "new voice"})

      assert Enum.map(Posts.discover_posts(viewer), & &1.id) == [fresh.id]
    end

    test "excludes the viewer's own posts" do
      viewer = user()
      create_post!(viewer, %{body: "mine"})

      assert Posts.discover_posts(viewer) == []
    end

    test "matches on locale, treating a missing locale as English" do
      german_viewer = user(locale: "de")
      unset_viewer = user(locale: nil)

      german_post = create_post!(user(locale: "de"), %{body: "auf Deutsch"})
      english_post = create_post!(user(locale: "en"), %{body: "in English"})
      unset_post = create_post!(user(locale: nil), %{body: "no locale set"})

      german_ids = Posts.discover_posts(german_viewer) |> Enum.map(& &1.id)
      assert german_ids == [german_post.id]

      unset_ids = Posts.discover_posts(unset_viewer) |> Enum.map(& &1.id) |> Enum.sort()
      assert unset_ids == Enum.sort([english_post.id, unset_post.id])
    end

    test "excludes restricted posts, replies and image-only posts" do
      viewer = user()
      author = user()

      create_post!(author, %{body: "circle only", denials: [%{"wildcard" => "non_followers"}]})
      parent = create_post!(author, %{body: "parent"})
      {:ok, _reply} = Posts.create_reply(user(), parent, %{body: "an answer"})
      image = insert(:post_image, user: author, post: nil)
      create_post!(author, %{body: "", image_ids: [image.id]})

      assert Enum.map(Posts.discover_posts(viewer), & &1.id) == [parent.id]
    end

    test "excludes members with a block in either direction" do
      viewer = user()
      blocked = user()
      blocker = user()
      {:ok, _} = Vutuv.Social.block_user(viewer, blocked)
      {:ok, _} = Vutuv.Social.block_user(blocker, viewer)

      create_post!(blocked, %{body: "blocked by viewer"})
      create_post!(blocker, %{body: "blocked the viewer"})

      assert Posts.discover_posts(viewer) == []
    end

    test "excludes unconfirmed authors" do
      viewer = user()
      create_post!(user(email_confirmed?: false), %{body: "ghost"})

      assert Posts.discover_posts(viewer) == []
    end

    test "picks one post per author: their newest eligible one" do
      viewer = user()
      prolific = user()

      older = create_post!(prolific, %{body: "older"})
      backdate_post!(older, 60)
      newest = create_post!(prolific, %{body: "newest"})

      assert Enum.map(Posts.discover_posts(viewer), & &1.id) == [newest.id]
    end

    test "returns at most limit posts and randomizes which authors it draws" do
      viewer = user()
      for n <- 1..8, do: create_post!(user(), %{body: "voice #{n}"})

      found = Posts.discover_posts(viewer, limit: 5)
      assert length(found) == 5

      # Across enough draws the random pick surfaces more than one slate.
      seen =
        Enum.reduce(1..20, MapSet.new(), fn _, seen ->
          Posts.discover_posts(viewer, limit: 5)
          |> Enum.map(& &1.user_id)
          |> MapSet.new()
          |> MapSet.union(seen)
        end)

      assert MapSet.size(seen) > 5
    end
  end

  describe "author_posts_page/4 with reposts" do
    test "pages posts and reposts together and scopes the period by event date" do
      author = user()
      original = create_post!(user(), %{body: "shared"})
      own = create_post!(author, %{body: "own"})
      :ok = Posts.repost_post(author, original)

      {entries, total} = Posts.author_posts_page(author, nil, %{})
      assert total == 2
      assert Enum.map(entries, & &1.post.id) |> Enum.sort() == Enum.sort([original.id, own.id])

      # `published_on` (and the repost's on_date) is the Berlin calendar day, so
      # the period must be built from the Berlin day too — a plain Date.utc_today()
      # diverges for the ~2h each night when the Berlin date is already tomorrow.
      today = Vutuv.BerlinTime.today()
      {entries, total} = Posts.author_posts_page(author, nil, %{}, {today, today})
      assert total == 2
      assert length(entries) == 2

      # A period before the repost excludes both entries.
      past = Date.add(today, -7)
      assert {[], 0} = Posts.author_posts_page(author, nil, %{}, {past, past})
    end
  end

  describe "liked and bookmarked posts pages" do
    test "lists liked posts newest-liked-first with offset pagination" do
      reader = user()
      posts = for n <- 1..3, do: create_post!(user(), %{body: "post #{n}"})

      for {post, index} <- Enum.with_index(posts) do
        :ok = Posts.like_post(reader, post)
        # Spread the like times so the order is deterministic.
        at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), index - 10)

        Repo.update_all(
          from(l in Vutuv.Posts.PostLike, where: l.post_id == ^post.id),
          set: [inserted_at: at]
        )
      end

      page1 = Posts.liked_posts_page(reader, limit: 2)
      assert page1.more?
      assert Enum.map(page1.entries, & &1.body) == ["post 3", "post 2"]

      page2 = Posts.liked_posts_page(reader, limit: 2, offset: page1.next_offset)
      refute page2.more?
      assert Enum.map(page2.entries, & &1.body) == ["post 1"]
    end

    test "the saved posts list filters by search and sorts oldest-first" do
      reader = user()
      alice = user(first_name: "Alice")
      first = create_post!(alice, %{body: "elixir tips"})
      second = create_post!(user(), %{body: "ruby tips"})
      :ok = Posts.bookmark_post(reader, first)
      :ok = Posts.bookmark_post(reader, second)

      # Match on the post body...
      assert [%Post{} = p] = Posts.bookmarked_posts_page(reader, search: "elixir").entries
      assert p.id == first.id
      # ...and on the author name.
      assert [%Post{} = p2] = Posts.bookmarked_posts_page(reader, search: "alice").entries
      assert p2.id == first.id

      # Oldest-first returns the earliest-saved post first.
      assert [%Post{id: oldest_id} | _] =
               Posts.bookmarked_posts_page(reader, sort: :oldest).entries

      assert oldest_id == first.id
    end

    test "hides liked posts that are no longer visible to the user" do
      reader = user()
      author = user()
      post = create_post!(author, %{body: "was public"})
      :ok = Posts.like_post(reader, post)

      {:ok, _} =
        Posts.update_post(post, %{body: "was public", denials: [%{"wildcard" => "everyone"}]})

      assert %{entries: []} = Posts.liked_posts_page(reader)
    end

    test "lists bookmarked posts" do
      reader = user()
      post = create_post!(user(), %{body: "keep this"})
      :ok = Posts.bookmark_post(reader, post)

      assert %{entries: [%Post{id: id}], more?: false} = Posts.bookmarked_posts_page(reader)
      assert id == post.id
    end
  end

  describe "update_post/2" do
    test "updates the body and replaces denials and tags" do
      author = user()
      stranger = user()

      post =
        create_post!(author, %{
          body: "v1",
          tags: "elixir",
          denials: [%{"wildcard" => "everyone"}]
        })

      assert {:ok, updated} =
               Posts.update_post(post, %{
                 body: "v2",
                 tags: "phoenix",
                 denials: [%{"wildcard" => "logged_out"}]
               })

      assert updated.body == "v2"
      assert [%PostDenial{wildcard: "logged_out"}] = updated.denials
      assert [%{name: "phoenix"}] = updated.tags
      # The everyone denial is gone: members can see it now.
      assert Posts.visible_to?(updated, stranger)
      # The publication date (the archive coordinate) never changes on edit.
      assert updated.published_on == post.published_on
    end

    test "clears denials when given an empty list" do
      author = user()
      post = create_post!(author, %{body: "x", denials: [%{"wildcard" => "everyone"}]})

      assert {:ok, updated} = Posts.update_post(post, %{body: "x", denials: []})
      assert updated.denials == []
      assert Repo.aggregate(PostDenial, :count) == 0
    end

    test "removes detached images and attaches new pending ones" do
      author = user()
      keep = insert(:post_image, user: author, post: nil)
      drop = insert(:post_image, user: author, post: nil)
      post = create_post!(author, %{body: "x", image_ids: [keep.id, drop.id]})

      fresh = insert(:post_image, user: author, post: nil)

      assert {:ok, updated} =
               Posts.update_post(post, %{body: "x", image_ids: [fresh.id, keep.id]})

      assert Enum.map(updated.images, & &1.id) == [fresh.id, keep.id]
      assert Enum.map(updated.images, & &1.position) == [0, 1]
      refute Repo.get(PostImage, drop.id)
    end
  end

  describe "delete_post/1" do
    test "deletes the post and its dependent rows" do
      author = user()
      image = insert(:post_image, user: author, post: nil)

      post =
        create_post!(author, %{
          body: "bye",
          tags: "elixir",
          image_ids: [image.id],
          denials: [%{"wildcard" => "everyone"}]
        })

      assert {:ok, _} = Posts.delete_post(post)
      refute Repo.get(Post, post.id)
      assert Repo.aggregate(PostDenial, :count) == 0
      assert Repo.aggregate(PostTag, :count) == 0
      refute Repo.get(PostImage, image.id)
    end
  end

  describe "permalink lookup" do
    test "get_post/2 finds by author and id" do
      author = user()
      post = create_post!(author, %{body: "find me"})

      found = Posts.get_post(author, post.id)
      assert found.id == post.id
      assert found.user.id == author.id

      # Another author's slug never resolves the post; garbage ids are a
      # nil, not a CastError.
      refute Posts.get_post(user(), post.id)
      refute Posts.get_post(author, Vutuv.UUIDv7.generate())
      refute Posts.get_post(author, "not-a-uuid")
    end
  end

  describe "restricted?/1" do
    test "is true exactly when the post has denials" do
      author = user()
      refute Posts.restricted?(create_post!(author, %{body: "open"}))

      assert Posts.restricted?(
               create_post!(author, %{body: "x", denials: [%{"wildcard" => "logged_out"}]})
             )
    end
  end

  describe "pending images" do
    test "update_image_alt/2 stores trimmed alt text" do
      image = insert(:post_image, user: user(), post: nil)
      assert {:ok, updated} = Posts.update_image_alt(image, "  Sunset over the Rhine ")
      assert updated.alt == "Sunset over the Rhine"
    end

    test "image_visible_to?/2: pending images only for their uploader" do
      uploader = user()
      image = insert(:post_image, user: uploader, post: nil)

      assert Posts.image_visible_to?(image, uploader)
      refute Posts.image_visible_to?(image, user())
      refute Posts.image_visible_to?(image, nil)
    end

    test "image_visible_to?/2 follows the post's audience" do
      author = user()
      image = insert(:post_image, user: author, post: nil)

      create_post!(author, %{
        body: "x",
        image_ids: [image.id],
        denials: [%{"wildcard" => "logged_out"}]
      })

      image = Repo.get(PostImage, image.id)
      assert Posts.image_visible_to?(image, user())
      refute Posts.image_visible_to?(image, nil)
    end

    test "sweep_pending_images/0 removes stale unattached images only" do
      author = user()
      stale = insert(:post_image, user: author, post: nil)
      fresh = insert(:post_image, user: author, post: nil)
      attached = insert(:post_image, user: author, post: nil)
      create_post!(author, %{body: "x", image_ids: [attached.id]})

      old = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -2 * 24 * 3600)

      Repo.update_all(
        from(i in PostImage, where: i.id in ^[stale.id, attached.id]),
        set: [inserted_at: old]
      )

      assert Posts.sweep_pending_images() == 1
      refute Repo.get(PostImage, stale.id)
      assert Repo.get(PostImage, fresh.id)
      assert Repo.get(PostImage, attached.id)
    end
  end

  describe "post_engagement_map/2" do
    test "batches the same engagement post_engagement/2 returns per post" do
      author = user()
      viewer = user()
      other = user()

      p1 = create_post!(author, %{body: "one"})
      p2 = create_post!(author, %{body: "two"})

      :ok = Posts.like_post(viewer, p1)
      :ok = Posts.like_post(other, p1)
      :ok = Posts.bookmark_post(viewer, p2)

      map = Posts.post_engagement_map([p1.id, p2.id], viewer)

      # Each batched entry is byte-for-byte the single-post query (the shared
      # select guarantees the shape can't drift), so the action bar is fed the
      # exact same data whether it was preloaded or self-loaded.
      assert map[p1.id] == Posts.post_engagement(p1.id, viewer)
      assert map[p2.id] == Posts.post_engagement(p2.id, viewer)

      # ...and the values are right: p1 has two likes incl. the viewer's; the
      # viewer bookmarked (but did not like) p2.
      assert map[p1.id].likes == 2
      assert map[p1.id].liked? == true
      assert map[p2.id].bookmarked? == true
      assert map[p2.id].liked? == false
    end

    test "an anonymous viewer gets the counts with every flag false" do
      post = create_post!(user(), %{body: "x"})
      :ok = Posts.like_post(user(), post)

      map = Posts.post_engagement_map([post.id], nil)

      assert map[post.id].likes == 1
      assert map[post.id].liked? == false
    end
  end

  describe "likes and bookmarks" do
    test "like_post/2 likes once, idempotently" do
      reader = user()
      post = create_post!(user(), %{body: "likeable"})

      assert :ok = Posts.like_post(reader, post)
      assert :ok = Posts.like_post(reader, post)
      assert %{likes: 1, bookmarks: 0, reposts: 0} = Posts.engagement_counts(post.id)
    end

    test "a fresh like pushes a live notification to the author, repeats and self-likes do not" do
      author = user()
      fan = user()
      post = create_post!(author, %{body: "likeable"})

      Vutuv.Activity.subscribe(author.id)

      :ok = Posts.like_post(fan, post)
      assert_receive {:new_notification, %{kind: "like", post_id: post_id}}
      assert post_id == post.id

      # The idempotent repeat is a no-op, not a second notification.
      :ok = Posts.like_post(fan, post)
      refute_receive {:new_notification, _}, 50

      # Liking your own post is not news.
      :ok = Posts.like_post(author, post)
      refute_receive {:new_notification, _}, 50
    end

    test "unlike_post/2 removes the like" do
      reader = user()
      post = create_post!(user(), %{body: "x"})

      :ok = Posts.like_post(reader, post)
      assert :ok = Posts.unlike_post(reader, post)
      assert :ok = Posts.unlike_post(reader, post)
      assert %{likes: 0} = Posts.engagement_counts(post.id)
    end

    test "a denied viewer cannot like or bookmark the post" do
      denied = user()

      post =
        create_post!(user(), %{body: "x", denials: [%{"denied_user_id" => denied.id}]})

      assert {:error, :not_visible} = Posts.like_post(denied, post)
      assert {:error, :not_visible} = Posts.bookmark_post(denied, post)
      assert %{likes: 0, bookmarks: 0} = Posts.engagement_counts(post.id)
    end

    test "bookmark_post/2 and unbookmark_post/2 toggle the bookmark" do
      reader = user()
      post = create_post!(user(), %{body: "x"})

      assert :ok = Posts.bookmark_post(reader, post)
      assert :ok = Posts.bookmark_post(reader, post)
      assert %{bookmarks: 1} = Posts.engagement_counts(post.id)

      assert :ok = Posts.unbookmark_post(reader, post)
      assert %{bookmarks: 0} = Posts.engagement_counts(post.id)
    end

    test "post_engagement/2 reports counts, viewer flags and restriction" do
      reader = user()
      other = user()
      post = create_post!(user(), %{body: "x"})

      :ok = Posts.like_post(reader, post)
      :ok = Posts.like_post(other, post)
      :ok = Posts.bookmark_post(reader, post)
      :ok = Posts.repost_post(other, post)

      assert %{
               likes: 2,
               bookmarks: 1,
               reposts: 1,
               liked?: true,
               bookmarked?: true,
               reposted?: false,
               restricted?: false
             } = Posts.post_engagement(post.id, reader)

      assert %{liked?: false, bookmarked?: false, reposted?: false} =
               Posts.post_engagement(post.id, nil)

      refute Posts.post_engagement(Vutuv.UUIDv7.generate(), reader)
    end

    test "toggles broadcast {:post_counters, …} with absolute counts" do
      reader = user()
      post = create_post!(user(), %{body: "x"})
      Posts.subscribe_post(post.id)

      :ok = Posts.like_post(reader, post)
      post_id = post.id
      assert_receive {:post_counters, %{post_id: ^post_id, likes: 1, bookmarks: 0, reposts: 0}}

      :ok = Posts.unlike_post(reader, post)
      assert_receive {:post_counters, %{post_id: ^post_id, likes: 0}}

      # A no-op toggle does not rebroadcast.
      :ok = Posts.unlike_post(reader, post)
      refute_receive {:post_counters, _}
    end
  end

  describe "repost_post/2" do
    test "reposts a public post once, idempotently" do
      reader = user()
      post = create_post!(user(), %{body: "spread me"})

      assert :ok = Posts.repost_post(reader, post)
      assert :ok = Posts.repost_post(reader, post)
      assert %{reposts: 1} = Posts.engagement_counts(post.id)
    end

    test "refuses restricted posts" do
      reader = user()
      author = user()
      follow!(reader, author)

      post =
        create_post!(author, %{body: "x", denials: [%{"wildcard" => "logged_out"}]})

      assert {:error, :restricted} = Posts.repost_post(reader, post)
      assert %{reposts: 0} = Posts.engagement_counts(post.id)
    end

    test "broadcasts {:new_repost, …} to the reposter and followers, once" do
      reposter = user()
      follower = user()
      follow!(follower, reposter)
      post = create_post!(user(), %{body: "x"})

      Vutuv.Activity.subscribe(follower.id)

      :ok = Posts.repost_post(reposter, post)
      post_id = post.id
      reposter_id = reposter.id

      assert_receive {:new_repost, %{post_id: ^post_id, reposter_id: ^reposter_id}}

      # Reposting again is a no-op and must not redistribute.
      :ok = Posts.repost_post(reposter, post)
      refute_receive {:new_repost, _}
    end

    test "unrepost_post/2 removes the repost" do
      reader = user()
      post = create_post!(user(), %{body: "x"})

      :ok = Posts.repost_post(reader, post)
      assert :ok = Posts.unrepost_post(reader, post)
      assert %{reposts: 0} = Posts.engagement_counts(post.id)
    end
  end

  describe "create_reply/3" do
    test "creates a normal post that references the parent" do
      author = user()
      replier = user()
      parent = create_post!(author, %{body: "original"})

      assert {:ok, %Post{} = reply} = Posts.create_reply(replier, parent, %{body: "an answer"})
      assert reply.body == "an answer"
      assert reply.published_on == Vutuv.BerlinTime.today()
      assert reply.reply_ref.parent_post_id == parent.id
      assert reply.reply_ref.parent_author_id == author.id
      assert reply.reply_ref.parent_post.id == parent.id
      assert reply.reply_ref.parent_author.id == author.id
    end

    test "the reply shows up in the replier's feed like any post" do
      replier = user()
      parent = create_post!(user(), %{body: "original"})
      {:ok, reply} = Posts.create_reply(replier, parent, %{body: "answer"})

      assert [entry] = Posts.feed_page(replier).entries
      assert entry.id == "post-#{reply.id}"
    end

    test "replies to replies form threads, each naming its direct parent" do
      a = user()
      b = user()
      parent = create_post!(a, %{body: "root"})

      {:ok, reply} = Posts.create_reply(b, parent, %{body: "first"})
      {:ok, nested} = Posts.create_reply(a, reply, %{body: "second"})

      assert nested.reply_ref.parent_post_id == reply.id
      assert nested.reply_ref.parent_author_id == b.id
    end

    test "a reply has no audience of its own: denials in attrs are ignored (issue #774)" do
      replier = user()
      parent = create_post!(user(), %{body: "original"})

      # A reply inherits the parent's (public) audience; it cannot be
      # independently restricted, so any denials in the params are dropped.
      assert {:ok, %Post{} = reply} =
               Posts.create_reply(replier, parent, %{
                 body: "secret answer",
                 denials: [%{"wildcard" => "everyone"}]
               })

      assert Repo.aggregate(from(d in PostDenial, where: d.post_id == ^reply.id), :count) == 0
      refute Posts.restricted?(Repo.preload(reply, :denials))
    end

    test "the reply count excludes a moderation-frozen reply (issue #774)" do
      parent = create_post!(user(), %{body: "root"})
      {:ok, _visible} = Posts.create_reply(user(), parent, %{body: "shown"})
      {:ok, frozen} = Posts.create_reply(user(), parent, %{body: "to be frozen"})

      # Moderation freezes the reply: it must vanish from the public count, like
      # it already does from the permalink thread (list_replies/scope_visible).
      Repo.update_all(from(p in Post, where: p.id == ^frozen.id),
        set: [frozen_at: NaiveDateTime.utc_now(:second)]
      )

      assert Posts.reply_count(parent.id) == 1
      assert %{replies: 1} = Posts.engagement_counts(parent.id)
    end

    test "the reply count excludes a legacy reply that carries its own denials" do
      parent = create_post!(user(), %{body: "root"})
      {:ok, _visible} = Posts.create_reply(user(), parent, %{body: "shown"})
      {:ok, legacy} = Posts.create_reply(user(), parent, %{body: "pre-#774 restricted reply"})

      # A reply created before this fix could carry denials; it must not be in
      # the public count either.
      Repo.insert!(%PostDenial{post_id: legacy.id, wildcard: "everyone"})

      assert Posts.reply_count(parent.id) == 1
      assert %{replies: 1} = Posts.engagement_counts(parent.id)
    end

    test "refuses a restricted parent" do
      replier = user()
      author = user()
      follow!(replier, author)
      parent = create_post!(author, %{body: "x", denials: [%{"wildcard" => "logged_out"}]})

      assert {:error, :restricted} = Posts.create_reply(replier, parent, %{body: "y"})
      assert Posts.reply_count(parent.id) == 0
    end

    test "refuses a parent restricted after it was loaded (stale struct)" do
      # The reply LiveView holds the parent from mount. If the author restricts
      # the post afterwards, a reply submitted against the stale (denials: [])
      # struct must still be refused — restriction is checked fresh from the DB.
      replier = user()
      author = user()
      follow!(replier, author)
      stale_parent = create_post!(author, %{body: "was public"})
      assert stale_parent.denials == []

      {:ok, _} =
        Posts.update_post(stale_parent, %{
          body: "now restricted",
          denials: [%{"wildcard" => "non_followers"}]
        })

      assert {:error, :restricted} = Posts.create_reply(replier, stale_parent, %{body: "y"})
      assert Posts.reply_count(stale_parent.id) == 0
    end

    test "refuses a parent the replier cannot see" do
      replier = user()

      parent =
        create_post!(user(), %{body: "x", denials: [%{"denied_user_id" => replier.id}]})

      assert {:error, :not_visible} = Posts.create_reply(replier, parent, %{body: "y"})
    end

    test "rejects an empty reply like an empty post" do
      parent = create_post!(user(), %{body: "x"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Posts.create_reply(user(), parent, %{body: "   "})

      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "broadcasts {:new_post, …} and the parent's fresh counters" do
      author = user()
      replier = user()
      parent = create_post!(author, %{body: "original"})

      Vutuv.Activity.subscribe(replier.id)
      Posts.subscribe_post(parent.id)

      {:ok, reply} = Posts.create_reply(replier, parent, %{body: "answer"})
      reply_id = reply.id
      parent_id = parent.id

      assert_receive {:new_post, %{post_id: ^reply_id}}
      assert_receive {:post_counters, %{post_id: ^parent_id, replies: 1}}
    end

    test "notifies the parent author, but not on self-replies" do
      author = user()
      parent = create_post!(author, %{body: "original"})

      Vutuv.Activity.subscribe(author.id)

      {:ok, _} = Posts.create_reply(user(), parent, %{body: "answer"})
      assert_receive {:new_notification, %{kind: "reply"}}

      {:ok, _} = Posts.create_reply(author, parent, %{body: "my own follow-up"})
      refute_receive {:new_notification, _}
    end
  end

  describe "reply tombstones" do
    test "a reply survives parent deletion, keeping the author reference" do
      author = user()
      parent = create_post!(author, %{body: "original"})
      {:ok, reply} = Posts.create_reply(user(), parent, %{body: "answer"})

      {:ok, _} = Posts.delete_post(parent)

      reply = Posts.get_post(reply.id)
      assert %PostReply{} = reply.reply_ref
      assert reply.reply_ref.parent_post_id == nil
      assert reply.reply_ref.parent_post == nil
      assert reply.reply_ref.parent_author.id == author.id
    end

    test "deleting the parent author's account clears both references" do
      author = user()
      parent = create_post!(author, %{body: "original"})
      {:ok, reply} = Posts.create_reply(user(), parent, %{body: "answer"})

      # The real account-deletion path: the DB cascade hard-deletes the
      # author's posts, so both parent references nilify together.
      Repo.delete!(author)

      reply = Posts.get_post(reply.id)
      assert %PostReply{} = reply.reply_ref
      assert reply.reply_ref.parent_post_id == nil
      assert reply.reply_ref.parent_author_id == nil
    end

    test "deleting the reply removes its reference row" do
      parent = create_post!(user(), %{body: "original"})
      {:ok, reply} = Posts.create_reply(user(), parent, %{body: "answer"})

      {:ok, _} = Posts.delete_post(reply)

      refute Repo.exists?(from(r in PostReply, where: r.post_id == ^reply.id))
      assert Posts.reply_count(parent.id) == 0
    end
  end

  describe "list_replies/3 and reply_count/1" do
    test "lists visible replies oldest first" do
      viewer = user()
      parent = create_post!(user(), %{body: "root"})

      {:ok, old} = Posts.create_reply(user(), parent, %{body: "older"})
      old = backdate_post!(old, 60)
      {:ok, new} = Posts.create_reply(user(), parent, %{body: "newer"})

      assert Enum.map(Posts.list_replies(parent, viewer), & &1.id) == [old.id, new.id]
    end

    test "the visible thread and the public count agree on a frozen reply (issue #774)" do
      # Replies can no longer be independently restricted, so the only way one
      # is hidden is a moderation freeze. The permalink thread and the public
      # count must then agree — the drift the issue was about is gone.
      viewer = user()
      parent = create_post!(user(), %{body: "root"})

      {:ok, frozen} = Posts.create_reply(user(), parent, %{body: "to be frozen"})
      {:ok, open} = Posts.create_reply(user(), parent, %{body: "open"})

      Repo.update_all(from(p in Post, where: p.id == ^frozen.id),
        set: [frozen_at: NaiveDateTime.utc_now(:second)]
      )

      assert Enum.map(Posts.list_replies(parent, viewer), & &1.id) == [open.id]
      assert Posts.reply_count(parent.id) == 1
    end

    test "reply counts appear in the engagement counters" do
      parent = create_post!(user(), %{body: "root"})
      {:ok, _} = Posts.create_reply(user(), parent, %{body: "a"})

      assert %{replies: 1} = Posts.engagement_counts(parent.id)
      assert %{replies: 1} = Posts.post_engagement(parent.id, nil)
    end
  end

  describe "visibility lock" do
    test "update_post/2 refuses audience changes while reposts exist" do
      author = user()
      post = create_post!(author, %{body: "public"})
      :ok = Posts.repost_post(user(), post)

      assert {:error, :visibility_locked} =
               Posts.update_post(post, %{
                 body: "public",
                 denials: [%{"wildcard" => "everyone"}]
               })

      # Body edits that keep the post public still work, and so does delete.
      assert {:ok, updated} = Posts.update_post(post, %{body: "edited", denials: []})
      assert updated.body == "edited"
      assert {:ok, _} = Posts.delete_post(post)
    end

    test "the lock lifts when the last repost is undone" do
      author = user()
      reposter = user()
      post = create_post!(author, %{body: "public"})

      :ok = Posts.repost_post(reposter, post)
      :ok = Posts.unrepost_post(reposter, post)

      assert {:ok, updated} =
               Posts.update_post(post, %{
                 body: "public",
                 denials: [%{"wildcard" => "everyone"}]
               })

      assert [%PostDenial{wildcard: "everyone"}] = updated.denials
    end

    test "update_post/2 refuses audience changes while replies exist" do
      author = user()
      post = create_post!(author, %{body: "public"})
      {:ok, reply} = Posts.create_reply(user(), post, %{body: "answer"})

      assert {:error, :visibility_locked} =
               Posts.update_post(post, %{
                 body: "public",
                 denials: [%{"wildcard" => "everyone"}]
               })

      # Deleting the reply lifts the lock.
      {:ok, _} = Posts.delete_post(reply)

      assert {:ok, updated} =
               Posts.update_post(post, %{
                 body: "public",
                 denials: [%{"wildcard" => "everyone"}]
               })

      assert [%PostDenial{wildcard: "everyone"}] = updated.denials
    end
  end

  describe "post deletion broadcasts" do
    test "delete_post/1 announces {:post_deleted} on the post topic and to followers' feeds" do
      author = user()
      follower = user()
      follow!(follower, author)
      post = create_post!(author, %{body: "bye"})
      post_id = post.id

      Posts.subscribe_post(post.id)
      Vutuv.Activity.subscribe(follower.id)

      {:ok, _} = Posts.delete_post(post)

      # Once on the post topic (open action bars empty), once on the
      # follower's feed topic (their feed drops the entry).
      assert_receive {:post_deleted, %{post_id: ^post_id}}
      assert_receive {:post_deleted, %{post_id: ^post_id}}
    end

    test "deleting a reply re-broadcasts the parent's fresh reply count" do
      author = user()
      parent = create_post!(author, %{body: "parent"})
      {:ok, reply} = Posts.create_reply(user(), parent, %{body: "child"})
      parent_id = parent.id

      Posts.subscribe_post(parent.id)
      {:ok, _} = Posts.delete_post(reply)

      assert_receive {:post_counters, %{post_id: ^parent_id, replies: 0}}
    end
  end
end
