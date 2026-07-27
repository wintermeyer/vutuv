defmodule Vutuv.FediversePostRepliesTest do
  @moduledoc """
  Answering a post by an account somebody follows on another network (issue
  #1165): what is created here, what the activity carries over there, and what
  refuses.

  `async: false` — the outbound reply budget lives in the shared
  `Vutuv.RateLimiter` ETS table, which the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias Vutuv.Posts.PostRemoteReply

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
      name: "Them Themself",
      inbox_uri: (attrs[:actor_uri] || @actor) <> "/inbox"
    })
  end

  defp cached_post(acc, audience \\ "public") do
    now = DateTime.utc_now(:second)

    Repo.insert!(%RemotePost{
      remote_account_id: acc.id,
      object_uri: "https://social.example/p/#{System.unique_integer([:positive])}",
      content_text: "Eine Frage in die Runde.",
      audience: audience,
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
    |> Repo.preload(:remote_account)
  end

  defp federating_member do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    Repo.reload!(user)
  end

  defp follow(user, acc, state \\ "accepted") do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: acc.id,
      state: state,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{acc.id}"
    })
  end

  defp queued do
    Repo.all(from(d in Delivery, order_by: [asc: d.id]))
    |> Enum.map(&Jason.decode!(&1.activity_json))
  end

  describe "the answer itself" do
    setup do
      %{user: federating_member(), post: cached_post(account())}
    end

    test "is a top-level vutuv post, not a reply to anything here", ctx do
      assert {:ok, post} =
               Posts.create_remote_post_reply(ctx.user, ctx.post, %{body: "Ja, klar."})

      # Nothing on this site sits above it: what it answers lives entirely on
      # somebody else's server.
      assert post.body == "Ja, klar."
      assert is_nil(post.reply_ref)
      assert Repo.aggregate(Vutuv.Posts.PostReply, :count) == 0
    end

    test "carries the sidecar with its own copy of everything delivery needs", ctx do
      {:ok, post} = Posts.create_remote_post_reply(ctx.user, ctx.post, %{body: "Ja, klar."})

      assert %PostRemoteReply{} = ref = Repo.get_by!(PostRemoteReply, post_id: post.id)
      assert ref.remote_post_id == ctx.post.id
      assert is_nil(ref.note_id)
      assert ref.in_reply_to_uri == ctx.post.object_uri
      assert ref.actor_uri == @actor
      assert ref.inbox_uri == @actor <> "/inbox"
      assert ref.handle == "@them@social.example"
    end

    test "threads over there: inReplyTo, the author in cc, a Mention from the stored URI", ctx do
      {:ok, _post} = Posts.create_remote_post_reply(ctx.user, ctx.post, %{body: "Ja, klar."})

      assert [%{"type" => "Create", "object" => note}] = queued()
      assert note["inReplyTo"] == ctx.post.object_uri
      assert @actor in note["cc"]

      # Built from the stored actor URI, never from parsing typed text — that
      # would let anybody mint a verified-looking Mention at any actor.
      assert Enum.any?(note["tag"], &(&1["type"] == "Mention" and &1["href"] == @actor))
    end

    test "outlives our copy of the post it answers", ctx do
      {:ok, post} = Posts.create_remote_post_reply(ctx.user, ctx.post, %{body: "Ja, klar."})

      Repo.delete!(ctx.post)

      # The answer stands and still knows where to go: the target id nilifies,
      # the copied address does not.
      assert %Vutuv.Posts.Post{} = Posts.get_post(post.id)
      ref = Repo.get_by!(PostRemoteReply, post_id: post.id)
      assert is_nil(ref.remote_post_id)
      assert ref.inbox_uri == @actor <> "/inbox"
    end
  end

  describe "the gates" do
    test "a followers-only post cannot be answered at all" do
      user = federating_member()
      acc = account()
      follow(user, acc)
      post = cached_post(acc, "followers")

      # The answer is a public vutuv post; republishing the audience its author
      # chose is not ours to do.
      assert {:error, :post_not_public} = Fediverse.check_remote_post_reply(user, post)

      assert {:error, :post_not_public} =
               Posts.create_remote_post_reply(user, post, %{body: "Doch nicht."})

      assert queued() == []
    end

    test "a member who does not federate is told which refusal it is" do
      user = insert(:activated_user)

      assert {:error, :not_federating} =
               Fediverse.check_remote_post_reply(user, cached_post(account()))
    end

    test "a blocked server refuses" do
      user = federating_member()
      post = cached_post(account(actor_uri: "https://blocked.example/users/them"))

      {:ok, _} =
        Fediverse.block_instance(%{"host" => "blocked.example"}, insert(:user, admin?: true))

      assert {:error, :instance_blocked} = Fediverse.check_remote_post_reply(user, post)
    end

    test "the answer budget is the reply budget, shared on purpose" do
      Application.put_env(:vutuv, :fediverse_outbound_reply_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_outbound_reply_limit) end)

      user = federating_member()
      acc = account()

      assert {:ok, _} = Posts.create_remote_post_reply(user, cached_post(acc), %{body: "Eins."})

      assert {:error, :reply_capped} =
               Posts.create_remote_post_reply(user, cached_post(acc), %{body: "Zwei."})
    end
  end

  describe "what can change while the form sits open" do
    setup do
      %{user: federating_member(), post: cached_post(account())}
    end

    test "a post deleted meanwhile is an answer, not a crash", ctx do
      # Another member's report, expiry, an upstream Delete, an instance block:
      # the row goes while somebody is still typing. Writing the sidecar against
      # it would hit the foreign key and take the LiveView down.
      Repo.delete!(ctx.post)

      assert {:error, :not_found} =
               Posts.create_remote_post_reply(ctx.user, ctx.post, %{body: "Zu spät."})

      assert queued() == []
    end

    test "an author narrowing the audience meanwhile is honoured", ctx do
      # The card said public when it rendered. Answering has to read what is
      # true now, or this feature's one rule is bypassed by having the form
      # open when the author changed their mind.
      Repo.update_all(RemotePost, set: [audience: "followers"])

      assert {:error, :post_not_public} =
               Posts.create_remote_post_reply(ctx.user, ctx.post, %{body: "Doch nicht."})

      assert queued() == []
    end
  end

  describe "where the answer goes" do
    test "to the author's own inbox and to the member's own remote followers" do
      user = federating_member()
      post = cached_post(account())

      Repo.insert!(%Vutuv.Fediverse.Follower{
        user_id: user.id,
        actor_uri: "https://elsewhere.example/users/fan",
        inbox_uri: "https://elsewhere.example/users/fan/inbox",
        handle: "fan"
      })

      {:ok, _} = Posts.create_remote_post_reply(user, post, %{body: "Für alle."})

      inboxes = Repo.all(from(d in Delivery, select: d.inbox_uri))

      # Both halves: the person answered, and the member's own audience.
      assert (@actor <> "/inbox") in inboxes
      assert "https://elsewhere.example/users/fan/inbox" in inboxes
    end

    test "a member who follows nobody may still answer a cached public post" do
      # Deliberate, and the same call the like path makes: the account page
      # shows public posts of accounts the reader does not follow, so what they
      # are shown they may answer.
      user = federating_member()

      assert {:ok, _} =
               Posts.create_remote_post_reply(user, cached_post(account()), %{body: "Hallo."})
    end
  end

  describe "the shared budget" do
    test "one hour's worth is spent across both kinds of answer" do
      Application.put_env(:vutuv, :fediverse_outbound_reply_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_outbound_reply_limit) end)

      user = federating_member()
      acc = account()

      # Both are the same act — a member's own words leaving for a server that
      # never followed them — so one must not hide inside the other's budget.
      assert {:ok, _} = Posts.create_remote_post_reply(user, cached_post(acc), %{body: "Eins."})
      assert {:error, :reply_capped} = Fediverse.claim_reply_budget(user)
    end
  end
end
