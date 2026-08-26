defmodule Vutuv.FeedAboutMeTest do
  @moduledoc """
  What happens to the reader's **own** posts reaches their feed, whoever did it.

  The feed is a follow feed: it answers "what have the people I follow said".
  That leaves a hole around the reader themselves — somebody they do not follow
  answers one of their posts, or passes it on, and the feed says nothing, so the
  conversation under their own words happens somewhere they never look. This
  source closes it, and it is scoped tightly: only the reader's own posts and
  the posts they reshared, never a stranger's activity in general.

  The gates are the ones every other source applies (blocks, mutes, moderation,
  audience), asked here of somebody the reader has no follow edge to at all.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.PostsHelpers, only: [backdate_post!: 2, backdate_repost!: 3]

  alias Vutuv.Posts
  alias Vutuv.Social

  # The reader, who follows one unrelated member so /feed has a follow set at
  # all — this source must not be what makes their feed non-empty.
  defp reader do
    user = insert(:activated_user)
    Social.follow(user, insert(:activated_user).id)
    user
  end

  defp stranger, do: insert(:activated_user)

  defp bodies(user, opts \\ []) do
    user
    |> Posts.feed_page(opts)
    |> Map.fetch!(:entries)
    |> Enum.flat_map(fn entry ->
      case entry do
        %{post: %{body: body}} when is_binary(body) -> [body | ancestor_bodies(entry)]
        _ -> []
      end
    end)
  end

  defp ancestor_bodies(entry), do: Enum.map(entry[:ancestors] || [], & &1.body)

  defp entry_for(user, body) do
    user
    |> Posts.feed_page()
    |> Map.fetch!(:entries)
    |> Enum.find(&(&1[:post] && &1.post.body == body))
  end

  describe "somebody answers one of my posts" do
    test "a stranger's reply reaches me" do
      me = reader()
      {:ok, mine} = Posts.create_post(me, %{body: "meine Frage"})
      {:ok, _reply} = Posts.create_reply(stranger(), mine, %{body: "die Antwort eines Fremden"})

      assert "die Antwort eines Fremden" in bodies(me)
    end

    test "an answer to a post I reshared reaches me too" do
      # "a post or a reshare of mine": passing something on is taking part in
      # it, so what is said under it is the reader's business as well.
      me = reader()
      {:ok, theirs} = Posts.create_post(stranger(), %{body: "ein fremder Beitrag"})
      :ok = Posts.repost_post(me, theirs)
      {:ok, _reply} = Posts.create_reply(stranger(), theirs, %{body: "eine Antwort darunter"})

      assert "eine Antwort darunter" in bodies(me)
    end

    test "a stranger's post that answers nothing of mine stays out" do
      me = reader()
      other = stranger()
      {:ok, theirs} = Posts.create_post(other, %{body: "ein fremder Beitrag"})
      {:ok, _reply} = Posts.create_reply(stranger(), theirs, %{body: "eine fremde Antwort"})

      refute "ein fremder Beitrag" in bodies(me)
      refute "eine fremde Antwort" in bodies(me)
    end

    test "a blocked member's reply does not reach me" do
      me = reader()
      blocked = stranger()
      {:ok, mine} = Posts.create_post(me, %{body: "meine Frage"})
      {:ok, _reply} = Posts.create_reply(blocked, mine, %{body: "eine unerwuenschte Antwort"})
      {:ok, _} = Social.block_user(me, blocked)

      refute "eine unerwuenschte Antwort" in bodies(me)
    end

    test "a muted member's reply does not reach me" do
      # Muting is "keep their posts out of my feed", and an answer under my post
      # is still one of their posts.
      me = reader()
      muted = stranger()
      Social.follow(me, muted.id)
      Social.toggle_follow_mute!(me.id, Social.follow_id(me.id, muted.id))

      {:ok, mine} = Posts.create_post(me, %{body: "meine Frage"})
      {:ok, _reply} = Posts.create_reply(muted, mine, %{body: "eine stummgeschaltete Antwort"})

      refute "eine stummgeschaltete Antwort" in bodies(me)
    end
  end

  describe "somebody reshares one of my posts" do
    test "a stranger's reshare brings my post back up" do
      me = reader()
      {:ok, mine} = Posts.create_post(me, %{body: "mein Beitrag"})
      backdate_post!(mine, 120)
      :ok = Posts.repost_post(stranger(), mine)

      entry = entry_for(me, "mein Beitrag")

      assert entry, "my own post should be on the page"
      assert entry.reposted_by, "and it should say who passed it on"
    end

    test "a stranger resharing a post I reshared reaches me" do
      # My own reshare already puts it on the page, so the claim has to be about
      # WHOSE reshare the entry carries: the newest one wins (`collapse_reposts/1`).
      me = reader()
      other = stranger()
      {:ok, theirs} = Posts.create_post(stranger(), %{body: "ein fremder Beitrag"})
      backdate_post!(theirs, 300)
      :ok = Posts.repost_post(me, theirs)
      backdate_repost!(me, theirs, 120)
      :ok = Posts.repost_post(other, theirs)

      entry = entry_for(me, "ein fremder Beitrag")

      assert entry
      assert entry.reposted_by.id == other.id
    end

    test "a blocked member's reshare does not reach me" do
      me = reader()
      blocked = stranger()
      {:ok, mine} = Posts.create_post(me, %{body: "mein Beitrag"})
      :ok = Posts.repost_post(blocked, mine)
      {:ok, _} = Social.block_user(me, blocked)

      entry = entry_for(me, "mein Beitrag")

      # The post is mine, so it is on the page either way — what must not be
      # there is the blocked member's name on it.
      assert entry
      refute entry.reposted_by
    end
  end

  describe "it arrives live, not only on the next load" do
    # The pull side and the push side have to agree, or the feed only catches up
    # when the reader reloads. A stranger is nobody's follower, so the ordinary
    # fan-out (`author + their followers`) never reaches the person whose post
    # is being answered.
    test "a stranger's reply reaches the author's activity topic" do
      me = reader()
      {:ok, mine} = Posts.create_post(me, %{body: "meine Frage"})
      Vutuv.Activity.subscribe(me.id)

      {:ok, reply} = Posts.create_reply(stranger(), mine, %{body: "die Antwort eines Fremden"})

      assert_receive {:new_post, %{post_id: post_id}}
      assert post_id == reply.id
    end

    test "a stranger's reshare reaches the author's activity topic" do
      me = reader()
      {:ok, mine} = Posts.create_post(me, %{body: "mein Beitrag"})
      Vutuv.Activity.subscribe(me.id)

      :ok = Posts.repost_post(stranger(), mine)

      assert_receive {:new_repost, %{post_id: post_id}}
      assert post_id == mine.id
    end

    test "the author is told once, not twice, when they follow the stranger" do
      # The ordinary fan-out already reaches a follower; this must not add a
      # second copy, which would count the same post twice behind the pill.
      me = reader()
      other = stranger()
      Social.follow(me, other.id)
      {:ok, mine} = Posts.create_post(me, %{body: "meine Frage"})
      Vutuv.Activity.subscribe(me.id)

      {:ok, _reply} = Posts.create_reply(other, mine, %{body: "die Antwort"})

      assert_receive {:new_post, _}
      refute_receive {:new_post, _}
    end
  end

  describe "the source tabs" do
    test "all of it counts as vutuv, not as fediverse" do
      me = reader()
      {:ok, mine} = Posts.create_post(me, %{body: "meine Frage"})
      {:ok, _reply} = Posts.create_reply(stranger(), mine, %{body: "die Antwort eines Fremden"})

      assert "die Antwort eines Fremden" in bodies(me, filter: :vutuv)
      refute "die Antwort eines Fremden" in bodies(me, filter: :fediverse)
    end
  end
end
