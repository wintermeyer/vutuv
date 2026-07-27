defmodule Vutuv.FediversePostLikesTest do
  @moduledoc """
  Liking a post from an account somebody follows on another network (issue
  #1164): what is stored, what leaves the building, and what refuses.

  `async: false` — the outbound budget lives in the shared `Vutuv.RateLimiter`
  ETS table, which the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.PostLike
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  @actor "https://social.example/users/them"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp account(attrs \\ []) do
    Repo.insert!(%RemoteAccount{
      actor_uri: attrs[:actor_uri] || @actor,
      host: attrs[:host] || "social.example",
      handle: "them",
      inbox_uri: (attrs[:actor_uri] || @actor) <> "/inbox"
    })
  end

  defp cached_post(acc, audience \\ "public") do
    now = DateTime.utc_now(:second)

    Repo.insert!(%RemotePost{
      remote_account_id: acc.id,
      object_uri: "https://social.example/p/#{System.unique_integer([:positive])}",
      content_text: "Etwas Lesenswertes.",
      audience: audience,
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
    |> Repo.preload(:remote_account)
  end

  defp follow(user, account, state) do
    Repo.insert!(%Vutuv.Fediverse.Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: state,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{account.id}"
    })
  end

  # A member who really federates: the Like is signed with their own actor key,
  # so an actorless member has nothing to send.
  defp federating_member do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    Repo.reload!(user)
  end

  defp queued do
    Repo.all(from(d in Delivery, order_by: [asc: d.id]))
    |> Enum.map(&Jason.decode!(&1.activity_json))
  end

  describe "liking" do
    setup do
      %{user: federating_member(), post: cached_post(account())}
    end

    test "stores the marker and queues a signed Like to the author's own inbox", ctx do
      assert {:ok, :liked} = Fediverse.like_remote_post(ctx.user, ctx.post)

      assert Repo.aggregate(PostLike, :count) == 1
      assert [delivery] = Repo.all(Delivery)
      # The author's personal inbox, never the shared one: a like is addressed
      # to one person, and a shared inbox is for what a server fans out.
      assert delivery.inbox_uri == @actor <> "/inbox"

      assert [%{"type" => "Like", "object" => object, "to" => to}] = queued()
      assert object == ctx.post.object_uri
      # To the author alone — telling a member's own followers what they liked
      # would publish a reading habit nobody asked to publish.
      assert to == [@actor]
    end

    test "liking twice is one like and one activity", ctx do
      assert {:ok, :liked} = Fediverse.like_remote_post(ctx.user, ctx.post)
      assert {:ok, :already} = Fediverse.like_remote_post(ctx.user, ctx.post)

      assert Repo.aggregate(PostLike, :count) == 1
      assert length(queued()) == 1
    end

    test "a followers-only post may be liked, and the like still goes to the author alone", ctx do
      post = cached_post(ctx.post.remote_account, "followers")
      follow(ctx.user, ctx.post.remote_account, "accepted")

      assert {:ok, :liked} = Fediverse.like_remote_post(ctx.user, post)
      assert [%{"to" => [@actor]}] = queued()
    end
  end

  describe "unliking" do
    setup do
      user = federating_member()
      post = cached_post(account())
      {:ok, :liked} = Fediverse.like_remote_post(user, post)
      %{user: user, post: post}
    end

    test "drops the marker and queues the matching Undo", ctx do
      assert {:ok, :unliked} = Fediverse.unlike_remote_post(ctx.user, ctx.post)

      assert Repo.aggregate(PostLike, :count) == 0

      assert [%{"type" => "Like", "id" => like_id}, %{"type" => "Undo"} = undo] = queued()
      # The wrapped Like repeats the id the original carried, so the other
      # server drops that exact activity instead of guessing.
      assert undo["object"]["id"] == like_id
      assert undo["object"]["type"] == "Like"
    end

    test "unliking what was never liked sends nothing", ctx do
      {:ok, :unliked} = Fediverse.unlike_remote_post(ctx.user, ctx.post)
      before = length(queued())

      assert {:ok, :already} = Fediverse.unlike_remote_post(ctx.user, ctx.post)
      assert length(queued()) == before
    end

    test "a like → unlike → like cycle reuses one stable activity id", ctx do
      {:ok, :unliked} = Fediverse.unlike_remote_post(ctx.user, ctx.post)
      {:ok, :liked} = Fediverse.like_remote_post(ctx.user, ctx.post)

      ids = queued() |> Enum.filter(&(&1["type"] == "Like")) |> Enum.map(& &1["id"])
      assert [id, id] = ids
    end
  end

  describe "the gates" do
    test "a member who does not federate is told so, and nothing goes out" do
      user = insert(:activated_user)
      post = cached_post(account())

      assert {:error, :not_federating} = Fediverse.check_remote_like(user, post)
      assert {:error, :not_federating} = Fediverse.like_remote_post(user, post)
      assert queued() == []
    end

    test "a blocked server refuses in both directions" do
      user = federating_member()
      post = cached_post(account(actor_uri: "https://blocked.example/users/them"))

      {:ok, _} =
        Fediverse.block_instance(%{"host" => "blocked.example"}, insert(:user, admin?: true))

      assert {:error, :instance_blocked} = Fediverse.like_remote_post(user, post)
    end

    test "the hourly budget refuses past the limit" do
      Application.put_env(:vutuv, :fediverse_outbound_like_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_outbound_like_limit) end)

      user = federating_member()
      acc = account()

      assert {:ok, :liked} = Fediverse.like_remote_post(user, cached_post(acc))
      assert {:error, :like_capped} = Fediverse.like_remote_post(user, cached_post(acc))
    end

    test "a repeat that sends nothing does not spend a slot" do
      Application.put_env(:vutuv, :fediverse_outbound_like_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_outbound_like_limit) end)

      user = federating_member()
      post = cached_post(account())

      assert {:ok, :liked} = Fediverse.like_remote_post(user, post)
      # A double tap or a second tab: no activity goes out, so no budget goes
      # with it — and the one slot is still there for a real like.
      assert {:ok, :already} = Fediverse.like_remote_post(user, post)
      assert length(queued()) == 1
    end

    test "a capped like leaves no marker behind" do
      Application.put_env(:vutuv, :fediverse_outbound_like_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_outbound_like_limit) end)

      user = federating_member()
      acc = account()
      {:ok, :liked} = Fediverse.like_remote_post(user, cached_post(acc))

      assert {:error, :like_capped} = Fediverse.like_remote_post(user, cached_post(acc))
      # A heart painted for a like that never left would be the one
      # disagreement the member cannot fix from here, so the marker is rolled
      # back: the one row left is the first, real like.
      assert Repo.aggregate(PostLike, :count) == 1
    end

    test "taking a like back is never refused by the budget" do
      user = federating_member()
      acc = account()
      post = cached_post(acc)
      {:ok, :liked} = Fediverse.like_remote_post(user, post)

      # Spend the budget on a second post, so the unlike below meets an
      # exhausted one.
      Application.put_env(:vutuv, :fediverse_outbound_like_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_outbound_like_limit) end)
      {:error, :like_capped} = Fediverse.like_remote_post(user, cached_post(acc))

      # A withdrawal must not be refusable because somebody has been busy.
      assert {:ok, :unliked} = Fediverse.unlike_remote_post(user, post)
    end
  end

  describe "a post that is not there any more" do
    test "answers instead of crashing when the row went between render and click" do
      user = federating_member()
      post = cached_post(account())
      # The card was rendered a while ago; expiry, an upstream Delete, another
      # member's report or an instance block took the row in the meantime. The
      # insert would otherwise hit the foreign key and take the LiveView with it
      # (`on_conflict: :nothing` suppresses the unique violation, not this one).
      Repo.delete!(post)

      assert {:error, :not_found} = Fediverse.like_remote_post(user, post)
      assert Repo.aggregate(PostLike, :count) == 0
    end

    test "a followers-only post of an account the member does not follow is refused" do
      user = federating_member()
      post = cached_post(account(), "followers")

      # The id in a click is the member's to choose, so the gate cannot rely on
      # the page having rendered the card.
      assert {:error, :not_visible} = Fediverse.check_remote_like(user, post)
      assert {:error, :not_visible} = Fediverse.like_remote_post(user, post)
      assert Repo.aggregate(PostLike, :count) == 0
    end

    test "an open post of an account nobody follows may still be liked" do
      # This is what the account page shows: a cached post of an account the
      # reader does not follow. Liking what you are shown has to work.
      user = federating_member()

      assert {:ok, :liked} = Fediverse.like_remote_post(user, cached_post(account()))
    end
  end

  describe "leaving the Fediverse" do
    test "withdraws every like and drops the markers" do
      user = federating_member()
      post = cached_post(account())
      {:ok, :liked} = Fediverse.like_remote_post(user, post)

      assert Fediverse.drop_remote_likes(user) == 1

      assert Repo.aggregate(PostLike, :count) == 0
      # The favourite standing on their server under this member's name is
      # exactly what leaving has to take with it.
      assert Enum.any?(queued(), &(&1["type"] == "Undo"))
    end

    test "the Undo still goes out once the member has stopped federating" do
      user = federating_member()
      post = cached_post(account())
      {:ok, :liked} = Fediverse.like_remote_post(user, post)

      # A withdrawal happens exactly when the state that allowed the original
      # act is already gone (issue #1102), so it must not be gated on it.
      user = user |> Ecto.Changeset.change(fediverse_followers?: false) |> Repo.update!()

      assert {:ok, :unliked} = Fediverse.unlike_remote_post(user, post)
      assert Enum.any?(queued(), &(&1["type"] == "Undo"))
    end

    test "the export carries them, because they are the member's own data" do
      user = federating_member()
      post = cached_post(account())
      {:ok, :liked} = Fediverse.like_remote_post(user, post)

      assert [entry] = Vutuv.Export.build(user).fediverse_likes
      assert entry.post == post.object_uri
      assert entry.server == "social.example"
    end
  end

  describe "the marker's lifetime" do
    test "it goes with the cached post, and the like on their server stands" do
      user = federating_member()
      post = cached_post(account())
      {:ok, :liked} = Fediverse.like_remote_post(user, post)

      Repo.update_all(RemotePost, set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)])
      assert Fediverse.expire_due_remote_posts() == 1

      # No Undo: our copy of the post expired, which says nothing about what
      # the member thinks of it. Only they can take a like back.
      assert Repo.aggregate(PostLike, :count) == 0
      refute Enum.any?(queued(), &(&1["type"] == "Undo"))
    end

    test "the feed's batched lookup answers for a whole page" do
      user = federating_member()
      acc = account()
      liked = cached_post(acc)
      unliked = cached_post(acc)
      {:ok, :liked} = Fediverse.like_remote_post(user, liked)

      ids = Fediverse.liked_remote_post_ids(user, [liked.id, unliked.id])

      assert MapSet.member?(ids, liked.id)
      refute MapSet.member?(ids, unliked.id)
      # A logged-out reader likes nothing, and asking must not raise.
      assert Fediverse.liked_remote_post_ids(nil, [liked.id]) == MapSet.new()
    end
  end
end
