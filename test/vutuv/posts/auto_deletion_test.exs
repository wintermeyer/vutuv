defmodule Vutuv.Posts.AutoDeletionTest do
  @moduledoc """
  The automatic post deletion rule (issue #1255).

  The tests are written against `count_due/1` and `run_for/2` together on
  purpose: the settings page shows the member a number and then deletes, so
  the two have to agree about every exception — that agreement is the feature.
  """

  use Vutuv.DataCase, async: true

  import Vutuv.PostsHelpers

  alias Vutuv.AccountEvents
  alias Vutuv.Accounts
  alias Vutuv.Fediverse.Reaction
  alias Vutuv.Moderation.Case
  alias Vutuv.Posts
  alias Vutuv.Posts.AutoDeletion
  alias Vutuv.Posts.Post

  defp user(attrs \\ []), do: insert(:activated_user, attrs)

  # A member with the rule switched on. Every exception defaults the way the
  # settings page ships it, so each test only names what it changes.
  defp member(attrs \\ []) do
    user(Keyword.merge([auto_post_deletion?: true, auto_post_deletion_after_days: 30], attrs))
  end

  defp aged_post!(author, days_old, attrs \\ %{}) do
    post = create_post!(author, Map.merge(%{body: "Old enough"}, attrs))
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -days_old * 24 * 60 * 60)
    Repo.update_all(from(p in Post, where: p.id == ^post.id), set: [inserted_at: at])
    %{post | inserted_at: at}
  end

  defp exists?(%Post{id: id}), do: Repo.exists?(from(p in Post, where: p.id == ^id))

  describe "the age threshold" do
    test "deletes posts past the threshold and keeps everything younger" do
      author = member(auto_post_deletion_after_days: 30)
      old = aged_post!(author, 31)
      young = aged_post!(author, 29)

      assert AutoDeletion.count_due(author) == 1
      assert {:ok, 1} = AutoDeletion.run_for(author)

      refute exists?(old)
      assert exists?(young)
    end

    test "a one-day floor is a real option, not a rounding of 'today'" do
      author = member(auto_post_deletion_after_days: 1)
      yesterday = aged_post!(author, 2)
      today = create_post!(author, %{body: "Fresh"})

      assert {:ok, 1} = AutoDeletion.run_for(author)
      refute exists?(yesterday)
      assert exists?(today)
    end

    test "does nothing at all while the switch is off" do
      author = user(auto_post_deletion?: false, auto_post_deletion_after_days: 30)
      post = aged_post!(author, 400)

      assert AutoDeletion.count_due(author) == 0
      assert {:ok, 0} = AutoDeletion.run_for(author)
      assert exists?(post)
    end

    test "does nothing when the switch is on but no age was ever picked" do
      author = user(auto_post_deletion?: true, auto_post_deletion_after_days: nil)
      post = aged_post!(author, 4_000)

      refute AutoDeletion.active?(author)
      assert AutoDeletion.count_due(author) == 0
      assert {:ok, 0} = AutoDeletion.run_for(author)
      assert exists?(post)
    end

    test "never touches another member's posts" do
      author = member()
      stranger = user()
      mine = aged_post!(author, 90)
      theirs = aged_post!(stranger, 90)

      assert {:ok, 1} = AutoDeletion.run_for(author)
      refute exists?(mine)
      assert exists?(theirs)
    end
  end

  describe "what the rule never touches" do
    test "keeps the pinned post" do
      author = member()
      pinned = aged_post!(author, 90)
      other = aged_post!(author, 90)
      {:ok, author} = Posts.pin_to_profile(author, pinned)

      assert AutoDeletion.count_due(author) == 1
      assert {:ok, 1} = AutoDeletion.run_for(author)

      assert exists?(pinned)
      refute exists?(other)
    end

    test "keeps a post with an open moderation case, and lets it go once closed" do
      author = member()
      reported = aged_post!(author, 90)

      case_record =
        Repo.insert!(%Case{
          content_type: "post",
          content_id: reported.id,
          owner_id: author.id,
          status: "escalated"
        })

      assert AutoDeletion.count_due(author) == 0

      Repo.update!(Ecto.Changeset.change(case_record, status: "rejected"))
      assert AutoDeletion.count_due(author) == 1
    end

    test "keeps a frozen post" do
      author = member()
      post = aged_post!(author, 90)

      Repo.update_all(
        from(p in Post, where: p.id == ^post.id),
        set: [frozen_at: NaiveDateTime.utc_now(:second)]
      )

      assert AutoDeletion.count_due(author) == 0
    end
  end

  describe "the exceptions" do
    test "keeps posts with photos while keep_photos is on" do
      author = member()
      with_photo = aged_post!(author, 90)
      insert(:post_image, post: with_photo, user: author)
      plain = aged_post!(author, 90)

      assert AutoDeletion.count_due(author) == 1
      assert {:ok, 1} = AutoDeletion.run_for(author)
      assert exists?(with_photo)
      refute exists?(plain)

      {:ok, author} = Accounts.update_user(author, %{"auto_post_deletion_keep_photos?" => false})
      assert AutoDeletion.count_due(author) == 1
    end

    test "keeps book and film reviews with the photos" do
      author = member()
      review_post = aged_post!(author, 90)
      insert(:post_review, post: review_post)

      assert AutoDeletion.count_due(author) == 0
    end

    test "keeps a post somebody answered while keep_answered is on" do
      author = member()
      answered = aged_post!(author, 90)
      insert(:post_reply, parent_post: answered, parent_author: author, post: build(:post))

      assert AutoDeletion.count_due(author) == 0

      {:ok, author} =
        Accounts.update_user(author, %{"auto_post_deletion_keep_answered?" => false})

      assert AutoDeletion.count_due(author) == 1
    end

    test "keeps a post the author bookmarked themselves" do
      author = member()
      kept = aged_post!(author, 90)
      other = aged_post!(author, 90)
      :ok = Posts.bookmark_post(author, kept)

      assert {:ok, 1} = AutoDeletion.run_for(author)
      assert exists?(kept)
      refute exists?(other)
    end

    test "somebody else's bookmark is not the author's escape hatch" do
      author = member()
      post = aged_post!(author, 90)
      :ok = Posts.bookmark_post(user(), post)

      assert AutoDeletion.count_due(author) == 1
    end

    test "keeps the member's own replies unless they ask for them to go" do
      author = member()
      stranger = user()
      parent = create_post!(stranger, %{body: "A question"})
      {:ok, reply} = Posts.create_reply(author, parent, %{body: "An answer"})

      Repo.update_all(
        from(p in Post, where: p.id == ^reply.id),
        set: [inserted_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -90 * 86_400)]
      )

      assert AutoDeletion.count_due(author) == 0

      {:ok, author} =
        Accounts.update_user(author, %{"auto_post_deletion_delete_replies?" => true})

      assert AutoDeletion.count_due(author) == 1
      assert {:ok, 1} = AutoDeletion.run_for(author)
      refute exists?(reply)
    end
  end

  describe "the engagement floors" do
    test "keeps a post that reached the like floor, counting other networks too" do
      author = member(auto_post_deletion_min_likes: 2)
      local = aged_post!(author, 90)
      mixed = aged_post!(author, 90)
      quiet = aged_post!(author, 90)

      :ok = Posts.like_post(user(), local)
      :ok = Posts.like_post(user(), local)

      # One vutuv like and one favourite from another network is two likes —
      # the same figure the member is shown on the post itself.
      :ok = Posts.like_post(user(), mixed)
      remote_reaction!(mixed, "like")

      :ok = Posts.like_post(user(), quiet)

      assert AutoDeletion.count_due(author) == 1
      assert {:ok, 1} = AutoDeletion.run_for(author)

      assert exists?(local)
      assert exists?(mixed)
      refute exists?(quiet)
    end

    test "keeps a post that reached the bookmark floor" do
      author = member(auto_post_deletion_min_bookmarks: 2)
      saved = aged_post!(author, 90)
      other = aged_post!(author, 90)

      :ok = Posts.bookmark_post(user(), saved)
      :ok = Posts.bookmark_post(user(), saved)
      :ok = Posts.bookmark_post(user(), other)

      assert {:ok, 1} = AutoDeletion.run_for(author)
      assert exists?(saved)
      refute exists?(other)
    end

    test "keeps a post that reached the repost floor, counting boosts from other networks" do
      author = member(auto_post_deletion_min_reposts: 2)
      boosted = aged_post!(author, 90)
      other = aged_post!(author, 90)

      :ok = Posts.repost_post(user(), boosted)
      remote_reaction!(boosted, "announce")
      :ok = Posts.repost_post(user(), other)

      assert {:ok, 1} = AutoDeletion.run_for(author)
      assert exists?(boosted)
      refute exists?(other)
    end

    test "a floor of zero is off" do
      author = member(auto_post_deletion_min_likes: 0)
      post = aged_post!(author, 90)

      assert AutoDeletion.count_due(author) == 1
      assert {:ok, 1} = AutoDeletion.run_for(author)
      refute exists?(post)
    end
  end

  describe "run_for/2 and the sweeper clock" do
    test "stamps the clock even when it deletes nothing, so the member leaves the queue" do
      # The starvation rule: a member the sweeper can do nothing for must not
      # hold the front of the oldest-first batch forever.
      author = member()
      today = Vutuv.BerlinTime.today()

      assert Enum.any?(AutoDeletion.due_users(today), &(&1.id == author.id))
      assert {:ok, 0} = AutoDeletion.run_for(author, today: today)

      refute Enum.any?(AutoDeletion.due_users(today), &(&1.id == author.id))
      assert Repo.get!(Vutuv.Accounts.User, author.id).auto_post_deletion_swept_on == today
    end

    test "the same member is due again the next day" do
      author = member()
      today = Vutuv.BerlinTime.today()

      assert {:ok, 0} = AutoDeletion.run_for(author, today: today)
      tomorrow = Date.add(today, 1)

      assert Enum.any?(AutoDeletion.due_users(tomorrow), &(&1.id == author.id))
    end

    test "a member with the switch off is never in the queue" do
      author = user(auto_post_deletion?: false)
      refute Enum.any?(AutoDeletion.due_users(), &(&1.id == author.id))
    end

    test "caps one pass and leaves the rest for the next one" do
      author = member()
      for _ <- 1..3, do: aged_post!(author, 90)

      assert {:ok, 2} = AutoDeletion.run_for(author, limit: 2)
      assert AutoDeletion.count_due(author) == 1
    end

    test "the member's own confirmed run is not capped" do
      author = member()
      for _ <- 1..3, do: aged_post!(author, 90)

      assert {:ok, 3} = AutoDeletion.run_for(author, limit: :infinity)
      assert AutoDeletion.count_due(author) == 0
    end

    test "writes one activity-log entry per pass that deleted something" do
      author = member()
      aged_post!(author, 90)
      aged_post!(author, 90)

      assert {:ok, 2} = AutoDeletion.run_for(author)

      assert [event] =
               author
               |> AccountEvents.recent(50)
               |> Enum.filter(&(&1.kind == "posts_auto_deleted"))

      assert event.details["count"] == 2
    end

    test "writes nothing to the log on a pass that deleted nothing" do
      author = member()

      assert {:ok, 0} = AutoDeletion.run_for(author)

      assert author
             |> AccountEvents.recent(50)
             |> Enum.filter(&(&1.kind == "posts_auto_deleted")) == []
    end
  end

  describe "sweep/1" do
    test "walks every due member and skips the ones already swept today" do
      today = Vutuv.BerlinTime.today()
      first = member()
      second = member()
      aged_post!(first, 90)
      aged_post!(second, 90)

      assert AutoDeletion.sweep(today) >= 2
      assert AutoDeletion.count_due(first) == 0
      assert AutoDeletion.count_due(second) == 0

      aged_post!(first, 90)
      # Already swept today: the fresh backlog waits for tomorrow's pass.
      assert AutoDeletion.sweep(today) == 0
      assert AutoDeletion.count_due(first) == 1
    end
  end

  defp remote_reaction!(post, kind) do
    Repo.insert!(%Reaction{
      post_id: post.id,
      actor_uri: "https://remote.example/users/#{System.unique_integer([:positive])}",
      kind: kind,
      received_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end
end
