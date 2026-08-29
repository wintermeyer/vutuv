defmodule Vutuv.FeedMarksShapeTest do
  @moduledoc """
  The two shapes a feed source can be asked for (`Vutuv.Posts.feed_sources/3`,
  `shape:` on the source itself): `:entries`, everything a card draws, and
  `:marks`, the `id` and the `at` a counter needs (`Vutuv.FeedPage.mark/1`).

  The whole point of the cheap shape is that it is the *same rows*: the feed
  calendar's heatmap is asked to promise that a day it shades busy is a day the
  timeline really has something on, and the moment the two shapes disagree
  about which posts reach a reader that promise is broken silently — a wrong
  shade and a wrong tooltip, with nothing raising and nothing logged.

  Each pair shares one query builder, so what these tests guard is somebody
  splitting them again: change a `where` in one shape and only one shape moves.
  The awkward cases are deliberate — a muted server, a follow that is only
  pending, a boost of a post the reader may not see — because those are the
  clauses somebody would edit.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.PostBoost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Posts

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp account(host, actor, handle) do
    Repo.insert!(%RemoteAccount{
      actor_uri: actor,
      host: host,
      handle: handle,
      name: handle,
      inbox_uri: actor <> "/inbox"
    })
  end

  defp follow(user, account, state \\ "accepted") do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: state,
      muted: false,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
    })
  end

  defp post_from(actor, id, text, overrides \\ %{}) do
    :ok =
      Fediverse.record_remote_post(
        %{
          "type" => "Create",
          "actor" => actor,
          "object" =>
            Map.merge(
              %{
                "id" => actor <> "/posts/#{id}",
                "type" => "Note",
                "attributedTo" => actor,
                "content" => "<p>#{text}</p>",
                "published" => "2026-07-20T10:00:00Z",
                "to" => [@public]
              },
              overrides
            )
        },
        actor
      )
  end

  defp boost(account, fields) do
    Repo.insert!(
      struct(
        %PostBoost{
          remote_account_id: account.id,
          activity_id: account.actor_uri <> "#announces/#{System.unique_integer([:positive])}",
          announced_at: DateTime.utc_now(:second)
        },
        fields
      )
    )
  end

  # The `id` and `at` of every row a source hands over, in the source's own
  # order — everything the two shapes are required to agree on, and nothing
  # else. Through `Vutuv.FeedPage.mark/1`, the same projection the cheap shape
  # itself is defined by, so this cannot re-derive a different one and pass.
  defp marks(entries), do: Enum.map(entries, &Vutuv.FeedPage.mark/1)

  defp reload(user), do: Repo.get!(Vutuv.Accounts.User, user.id)

  @cap 100
  @cursor nil

  describe "remote posts" do
    setup do
      user = insert(:activated_user, fediverse_followers?: true)

      them = account("social.example", "https://social.example/users/them", "them")
      quiet = account("quiet.example", "https://quiet.example/users/quiet", "quiet")
      pending = account("later.example", "https://later.example/users/later", "later")

      follow(user, them)
      follow(user, quiet)
      pending_follow = follow(user, pending)

      post_from("https://social.example/users/them", 1, "Von drüben.")
      # Unlisted, not public: open enough to reach a reader, and the value that
      # tells a shape reading `audience == "public"` apart from one reading
      # `audience in open_audiences()`.
      post_from("https://social.example/users/them", 2, "Leise von drüben.", %{
        "to" => ["https://social.example/users/them/followers"],
        "cc" => [@public]
      })

      post_from("https://quiet.example/users/quiet", 3, "Von woanders.")
      # Only a follower may read this one, and by the time it is read the
      # follow is no longer accepted — the clause that drops it (`audience in
      # open_audiences() or state == "accepted"`) is one both shapes carry. The
      # follow is demoted *after* the ingest, which refuses a followers-only
      # post from an account that has not accepted us.
      post_from("https://later.example/users/later", 4, "Nur für Folgende.", %{
        "to" => ["https://later.example/users/later/followers"]
      })

      Repo.update!(Ecto.Changeset.change(pending_follow, state: "pending"))

      %{user: user}
    end

    test "both shapes name the same rows", %{user: user} do
      entries = Fediverse.feed_remote_posts(user, @cap, @cursor)

      assert marks(entries) == Fediverse.feed_remote_posts(user, @cap, @cursor, shape: :marks)
      assert length(entries) == 3
    end

    test "and still do with a server switched off", %{user: user} do
      {:ok, _} = Fediverse.set_host_mute(user, "quiet.example", true)
      user = reload(user)

      entries = Fediverse.feed_remote_posts(user, @cap, @cursor)

      assert marks(entries) == Fediverse.feed_remote_posts(user, @cap, @cursor, shape: :marks)
      assert length(entries) == 2
    end

    test "and under a language filter", %{user: user} do
      {:ok, user} = Vutuv.Accounts.update_user(user, %{feed_languages: ["de"]})

      assert marks(Fediverse.feed_remote_posts(user, @cap, @cursor)) ==
               Fediverse.feed_remote_posts(user, @cap, @cursor, shape: :marks)
    end

    test "and when the window cuts them off", %{user: user} do
      assert marks(Fediverse.feed_remote_posts(user, 1, @cursor)) ==
               Fediverse.feed_remote_posts(user, 1, @cursor, shape: :marks)
    end
  end

  describe "boosts" do
    setup do
      user = insert(:activated_user, fediverse_followers?: true)
      booster = account("social.example", "https://social.example/users/kurator", "kurator")
      follow(user, booster)

      author = insert(:activated_user, fediverse_followers?: true)
      Vutuv.Social.follow(user, author.id)

      post_from("https://social.example/users/kurator", 1, "Etwas von dort.")
      remote = Repo.one!(Vutuv.Fediverse.RemotePost)

      {:ok, open} = Posts.create_post(author, %{body: "Von hier, für alle."})

      # The post the reader may not see. `filter_visible_boosts/2` is what drops
      # it, in memory, after the query — so it is exactly the case a shape that
      # skipped the filter would get wrong while every query-level test stayed
      # green.
      {:ok, denied} =
        Posts.create_post(author, %{
          body: "Nur für wenige.",
          denials: [%{"denied_user_id" => user.id}]
        })

      boost(booster, %{remote_post_id: remote.id})
      boost(booster, %{post_id: open.id})
      boost(booster, %{post_id: denied.id})

      %{user: user, open: open}
    end

    test "both shapes name the same rows, and neither carries the hidden one", %{
      user: user,
      open: open
    } do
      entries = Fediverse.feed_remote_boosts(user, @cap, @cursor, [])

      assert marks(entries) == Fediverse.feed_remote_boosts(user, @cap, @cursor, shape: :marks)
      assert length(entries) == 2
      assert Enum.any?(entries, &(&1.post && &1.post.id == open.id))
    end

    test "and agree on each kind on its own", %{user: user} do
      for only <- [:local, :remote] do
        assert marks(Fediverse.feed_remote_boosts(user, @cap, @cursor, only: only)) ==
                 Fediverse.feed_remote_boosts(user, @cap, @cursor, only: only, shape: :marks)
      end
    end

    test "and still do with the booster's server switched off", %{user: user} do
      {:ok, _} = Fediverse.set_host_mute(user, "social.example", true)
      user = reload(user)

      assert Fediverse.feed_remote_boosts(user, @cap, @cursor, []) == []
      assert Fediverse.feed_remote_boosts(user, @cap, @cursor, shape: :marks) == []
    end
  end

  describe "the heatmap counts what the timeline shows" do
    test "a day of remote posts is counted, not guessed", %{} do
      user = insert(:activated_user, fediverse_followers?: true)
      them = account("social.example", "https://social.example/users/them", "them")
      follow(user, them)

      for n <- 1..3, do: post_from("https://social.example/users/them", n, "Beitrag #{n}")

      day = Vutuv.ViewerClock.date(~N[2026-07-20 10:00:00])
      %{counts: counts} = Posts.feed_activity_by_day(user, day, day)

      assert Map.get(counts, day) == 3
      assert length(Posts.feed_page(user, limit: 100).entries) == 3
    end
  end
end
