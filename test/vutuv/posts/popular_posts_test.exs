defmodule Vutuv.Posts.PopularPostsTest do
  @moduledoc """
  The snapshot behind the feed's "Vorschläge" rail, and the draw that reads it.

  Two halves, and the second one is the important one: the snapshot may be up
  to ten minutes old, so every test that matters here asks what happens when
  the world moved on after it was taken. The pool decides *candidacy*; the
  database still decides *visibility*, on every single draw.
  """
  use Vutuv.DataCase

  import Vutuv.QueryCounter

  alias Ecto.Adapters.SQL.Sandbox
  alias Vutuv.Accounts.User
  alias Vutuv.Posts
  alias Vutuv.Posts.PopularPosts
  alias Vutuv.Posts.Post

  # An isolated cache instance on its own table, so these tests never race the
  # application singleton (whose refresh timer is off in tests anyway).
  defp start_pool! do
    table = :"popular_posts_test_#{System.unique_integer([:positive])}"
    pid = start_supervised!({PopularPosts, name: nil, table: table, refresh?: false})
    Sandbox.allow(Vutuv.Repo, self(), pid)
    :ok = PopularPosts.refresh(pid)
    table
  end

  defp user(attrs \\ []), do: insert(:activated_user, attrs)

  defp liked_post!(author, body, likers \\ 2) do
    post = Vutuv.PostsHelpers.create_post!(author, %{body: body})
    for _ <- 1..likers//1, do: :ok = Posts.like_post(user(), post)
    post
  end

  defp backdate_post!(post, seconds) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -seconds)
    Repo.update_all(from(p in Post, where: p.id == ^post.id), set: [inserted_at: at])
    %{post | inserted_at: at}
  end

  defp set_user!(user, fields) do
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: fields)
    Repo.get!(User, user.id)
  end

  describe "the snapshot" do
    test "serves the locale's pool without a database round trip" do
      author = user(locale: "de")
      post = liked_post!(author, "entdecke mich")
      table = start_pool!()

      {result, queries} = count_queries(fn -> PopularPosts.top("de", table) end)

      assert {:ok, [%{id: id, user_id: user_id}]} = result
      assert id == post.id
      assert user_id == author.id
      assert queries == 0
    end

    test "keeps the locales apart" do
      german = liked_post!(user(locale: "de"), "auf deutsch")
      english = liked_post!(user(locale: "en"), "in english")
      table = start_pool!()

      assert {:ok, [%{id: id}]} = PopularPosts.top("de", table)
      assert id == german.id
      assert {:ok, [%{id: id}]} = PopularPosts.top("en", table)
      assert id == english.id
    end

    test "holds one post per author, their best-liked one" do
      prolific = user(locale: "de")
      best = liked_post!(prolific, "die gute", 4)
      liked_post!(prolific, "die schwächere", 2)

      table = start_pool!()

      assert {:ok, [%{id: id}]} = PopularPosts.top("de", table)
      assert id == best.id
    end

    test "ranks by likes, best first" do
      middling = liked_post!(user(locale: "de"), "ganz nett", 2)
      loved = liked_post!(user(locale: "de"), "grossartig", 5)

      table = start_pool!()

      assert {:ok, rows} = PopularPosts.top("de", table)
      assert Enum.map(rows, & &1.id) == [loved.id, middling.id]
    end

    test "holds only posts that cleared the like bar" do
      Vutuv.PostsHelpers.create_post!(user(locale: "de"), %{body: "niemand mag mich"})
      liked = liked_post!(user(locale: "de"), "beliebt")

      table = start_pool!()

      assert {:ok, [%{id: id}]} = PopularPosts.top("de", table)
      assert id == liked.id
    end

    test "misses on an unseeded table, an unknown table and an unknown locale" do
      table = :"popular_posts_test_#{System.unique_integer([:positive])}"
      pid = start_supervised!({PopularPosts, name: nil, table: table, refresh?: false})
      Sandbox.allow(Vutuv.Repo, self(), pid)

      # A miss, never a lie: the caller falls back to the live ladder.
      assert PopularPosts.top("de", table) == :miss
      assert PopularPosts.top("de", :no_such_table) == :miss

      :ok = PopularPosts.refresh(pid)
      assert PopularPosts.top("kl", table) == :miss
    end
  end

  describe "the draw that reads it" do
    test "suggests a stranger's well-liked post, author preloaded" do
      author = user(locale: "de")
      post = liked_post!(author, "entdecke mich")
      viewer = user(locale: "de")
      table = start_pool!()

      assert [found] = Posts.discover_posts(viewer, pool_table: table)
      assert found.id == post.id
      assert found.user.id == author.id
    end

    test "runs no ranking scan at all — that is the whole point" do
      liked_post!(user(locale: "de"), "entdecke mich")
      viewer = user(locale: "de")
      table = start_pool!()

      # The like rollup (post_likes UNION ALL fediverse_reactions) is the
      # expensive half of the ladder. On the cached path it must not run.
      {found, scans} =
        count_queries(fn -> Posts.discover_posts(viewer, pool_table: table) end,
          matching: "fediverse_reactions"
        )

      assert length(found) == 1
      assert scans == 0
    end

    test "prefers a stranger over someone the viewer already follows" do
      followed = user(locale: "de")
      stranger = user(locale: "de")
      liked_post!(followed, "von jemandem, dem ich folge")
      strangers_post = liked_post!(stranger, "von einer neuen Stimme")

      viewer = user(locale: "de")
      {:ok, _} = Vutuv.Social.follow(viewer, followed.id)
      table = start_pool!()

      assert Enum.map(Posts.discover_posts(viewer, limit: 1, pool_table: table), & &1.id) ==
               [strangers_post.id]
    end

    test "suggests a followed author only to fill the card, and only from the window" do
      followed = user(locale: "de")
      recent = liked_post!(followed, "aus dieser Woche")
      old = liked_post!(user(locale: "de"), "der Klassiker")
      old = backdate_post!(old, 20 * 24 * 60 * 60)

      viewer = user(locale: "de")
      {:ok, _} = Vutuv.Social.follow(viewer, followed.id)
      table = start_pool!()

      ids = Posts.discover_posts(viewer, pool_table: table) |> Enum.map(& &1.id)

      # The stranger's old favourite still qualifies (tier 2), the followed
      # author's post only because it is inside the fortnight (tier 3).
      assert Enum.sort(ids) == Enum.sort([recent.id, old.id])

      # Backdate the followed author's post out of the window and it goes:
      # an old post from someone you already read is not a discovery.
      backdate_post!(recent, 20 * 24 * 60 * 60)
      assert Enum.map(Posts.discover_posts(viewer, pool_table: table), & &1.id) == [old.id]
    end

    test "never suggests a muted followee, the viewer themselves, or a blocked member" do
      muted = user(locale: "de")
      blocked = user(locale: "de")
      viewer = user(locale: "de")

      liked_post!(muted, "still gestellt")
      liked_post!(blocked, "blockiert")
      liked_post!(viewer, "mein eigener")

      {:ok, _} = Vutuv.Social.follow(viewer, muted.id)
      Vutuv.Social.toggle_follow_mute!(viewer.id, Vutuv.Social.follow_id(viewer.id, muted.id))
      {:ok, _} = Vutuv.Social.block_user(viewer, blocked)

      table = start_pool!()

      assert Posts.discover_posts(viewer, pool_table: table) == []
    end

    test "matches the viewer's language" do
      german = liked_post!(user(locale: "de"), "auf deutsch")
      liked_post!(user(locale: "en"), "in english")
      table = start_pool!()

      assert Enum.map(Posts.discover_posts(user(locale: "de"), pool_table: table), & &1.id) ==
               [german.id]
    end

    test "fills the card and still varies between draws" do
      for n <- 1..8, do: liked_post!(user(locale: "de"), "Stimme #{n}")
      viewer = user(locale: "de")
      table = start_pool!()

      assert length(Posts.discover_posts(viewer, limit: 5, pool_table: table)) == 5

      # The shuffle lives inside the tier now (an earlier cut shuffled across
      # the whole set and silently lost the tier preference), so this asserts
      # the half that survived: within one tier the draw is still random.
      slates =
        Enum.reduce(1..20, MapSet.new(), fn _, seen ->
          Posts.discover_posts(viewer, limit: 5, pool_table: table)
          |> Enum.map(& &1.user_id)
          |> MapSet.new()
          |> MapSet.union(seen)
        end)

      assert MapSet.size(slates) > 5
    end

    test "falls back to recent posts when the pool is empty, as the ladder does" do
      # A brand-new installation: nothing has been liked, so nothing clears the
      # bar and the snapshot is legitimately empty — an answer, not a miss. The
      # rail must still not be permanently blank, which is the whole reason the
      # like-less fallback exists.
      post = Vutuv.PostsHelpers.create_post!(user(locale: "de"), %{body: "ganz frisch hier"})
      viewer = user(locale: "de")
      table = start_pool!()

      assert {:ok, []} = PopularPosts.top("de", table)
      assert Enum.map(Posts.discover_posts(viewer, pool_table: table), & &1.id) == [post.id]
    end

    test "falls back to recent posts when the viewer filtered the whole pool away" do
      # The pool is not empty, this reader's view of it is: they follow the one
      # author in it and the post is older than the fortnight, so no tier can
      # take it. Same rule, same fallback.
      author = user(locale: "de")
      old = liked_post!(author, "der Klassiker")
      backdate_post!(old, 20 * 24 * 60 * 60)

      viewer = user(locale: "de")
      {:ok, _} = Vutuv.Social.follow(viewer, author.id)
      fresh = Vutuv.PostsHelpers.create_post!(user(locale: "de"), %{body: "ungeliebt, aber neu"})

      table = start_pool!()
      assert {:ok, [_]} = PopularPosts.top("de", table)

      assert Enum.map(Posts.discover_posts(viewer, pool_table: table), & &1.id) == [fresh.id]
    end

    test "falls back to the live ladder when the snapshot cannot answer" do
      post = liked_post!(user(locale: "de"), "entdecke mich")
      viewer = user(locale: "de")

      # No snapshot: behaviour is unchanged, only uncached.
      assert Enum.map(Posts.discover_posts(viewer, pool_table: :no_such_table), & &1.id) ==
               [post.id]
    end
  end

  # The reason the pool may only ever propose a candidate: it is a snapshot,
  # and moderation is not. Each of these makes the world move after the
  # snapshot was taken and asserts the draw still refuses the post.
  describe "a stale pool never leaks a hidden post" do
    setup do
      author = user(locale: "de")
      post = liked_post!(author, "entdecke mich")
      viewer = user(locale: "de")
      table = start_pool!()

      # Sanity: it is in the pool and it is being suggested.
      assert {:ok, [_]} = PopularPosts.top("de", table)
      assert [_] = Posts.discover_posts(viewer, pool_table: table)

      %{author: author, post: post, viewer: viewer, table: table}
    end

    test "the post was frozen since", %{post: post, viewer: viewer, table: table} do
      Repo.update_all(from(p in Post, where: p.id == ^post.id),
        set: [frozen_at: NaiveDateTime.utc_now(:second)]
      )

      assert Posts.discover_posts(viewer, pool_table: table) == []
    end

    test "the author was frozen since", %{author: author, viewer: viewer, table: table} do
      set_user!(author, frozen_at: NaiveDateTime.utc_now(:second))
      assert Posts.discover_posts(viewer, pool_table: table) == []
    end

    test "the author was suspended since", %{author: author, viewer: viewer, table: table} do
      set_user!(author, suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(:second), 3600))
      assert Posts.discover_posts(viewer, pool_table: table) == []
    end

    test "the author deactivated since", %{author: author, viewer: viewer, table: table} do
      set_user!(author, deactivated_at: NaiveDateTime.utc_now(:second))
      assert Posts.discover_posts(viewer, pool_table: table) == []
    end

    test "the author became unreachable since", %{author: author, viewer: viewer, table: table} do
      set_user!(author, unreachable_at: NaiveDateTime.utc_now(:second))
      assert Posts.discover_posts(viewer, pool_table: table) == []
    end

    test "the post was restricted since", %{post: post, viewer: viewer, table: table} do
      Repo.insert!(%Vutuv.Posts.PostDenial{post_id: post.id, wildcard: "everyone"})
      assert Posts.discover_posts(viewer, pool_table: table) == []
    end

    test "the viewer blocked the author since", %{author: author, viewer: viewer, table: table} do
      {:ok, _} = Vutuv.Social.block_user(viewer, author)
      assert Posts.discover_posts(viewer, pool_table: table) == []
    end

    test "the viewer followed and muted the author since", %{
      author: author,
      viewer: viewer,
      table: table
    } do
      {:ok, _} = Vutuv.Social.follow(viewer, author.id)
      Vutuv.Social.toggle_follow_mute!(viewer.id, Vutuv.Social.follow_id(viewer.id, author.id))

      assert Posts.discover_posts(viewer, pool_table: table) == []
    end
  end
end
