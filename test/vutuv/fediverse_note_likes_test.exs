defmodule Vutuv.FediverseNoteLikesTest do
  @moduledoc """
  Liking a reply that arrived from another network under a vutuv post (issue
  #1270): what is stored, what leaves the building, and what refuses.

  The sibling of `Vutuv.FediversePostLikesTest`, and deliberately its shape —
  the two acts differ only in which row they are keyed to, so a claim that
  holds there and not here is a drift worth failing on.

  `async: false` — the outbound budget lives in the shared `Vutuv.RateLimiter`
  ETS table, which the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.NoteLike

  @actor "https://social.example/users/them"
  @inbox "https://social.example/users/them/inbox"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  # The member whose post the reply answers. Not the one doing the liking in
  # most tests — a reply under your own post is the common case, but liking one
  # is not the owner's privilege.
  defp author, do: insert(:activated_user)

  defp post_of(user), do: insert(:post, user: user)

  defp note(post, attrs \\ []) do
    now = DateTime.utc_now(:second)

    Repo.insert!(%Note{
      post_id: post.id,
      object_uri:
        attrs[:object_uri] || "https://social.example/n/#{System.unique_integer([:positive])}",
      actor_uri: attrs[:actor_uri] || @actor,
      origin_url: "https://social.example/@them/1",
      handle: "them",
      display_name: "Thea Remote",
      content_text: "Etwas Lesenswertes.",
      audience: attrs[:audience] || "public",
      inbox_uri: Keyword.get(attrs, :inbox_uri, @inbox),
      received_at: now,
      checked_at: now,
      expires_at: DateTime.add(now, 86_400)
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
    from(d in Delivery, order_by: [asc: d.id])
    |> Repo.all()
    |> Enum.map(&Jason.decode!(&1.activity_json))
  end

  describe "liking" do
    setup do
      %{user: federating_member(), note: note(post_of(author()))}
    end

    test "stores the marker and queues a signed Like to the author's own inbox", ctx do
      assert {:ok, :liked} = Fediverse.like_note(ctx.user, ctx.note)

      assert Repo.aggregate(NoteLike, :count) == 1
      assert [delivery] = Repo.all(Delivery)
      assert delivery.inbox_uri == @inbox

      assert [%{"type" => "Like", "object" => object, "to" => to}] = queued()
      assert object == ctx.note.object_uri
      # To the author alone — telling a member's own followers what they liked
      # would publish a reading habit nobody asked to publish.
      assert to == [@actor]
    end

    test "liking twice is one like and one activity", ctx do
      assert {:ok, :liked} = Fediverse.like_note(ctx.user, ctx.note)
      assert {:ok, :already} = Fediverse.like_note(ctx.user, ctx.note)

      assert Repo.aggregate(NoteLike, :count) == 1
      assert length(queued()) == 1
    end

    test "the member a private reply was addressed to may like it", _ctx do
      user = federating_member()
      note = note(post_of(user), audience: "direct")

      # No audience gate here, unlike answering: a Like is addressed to the
      # author alone and publishes nothing, so it cannot widen what its sender
      # chose.
      assert :ok = Fediverse.check_note_like(user, note)
      assert {:ok, :liked} = Fediverse.like_note(user, note)
      assert [%{"to" => [@actor]}] = queued()
    end

    test "which replies a member likes comes back in one query", ctx do
      other = note(post_of(author()))
      {:ok, :liked} = Fediverse.like_note(ctx.user, ctx.note)

      liked = Fediverse.liked_note_ids(ctx.user, [ctx.note.id, other.id])

      assert MapSet.member?(liked, ctx.note.id)
      refute MapSet.member?(liked, other.id)
      # A logged-out reader likes nothing, and must not blow up asking.
      assert MapSet.size(Fediverse.liked_note_ids(nil, [ctx.note.id])) == 0
    end
  end

  describe "unliking" do
    setup do
      user = federating_member()
      note = note(post_of(author()))
      {:ok, :liked} = Fediverse.like_note(user, note)
      %{user: user, note: note}
    end

    test "drops the marker and queues the matching Undo", ctx do
      assert {:ok, :unliked} = Fediverse.unlike_note(ctx.user, ctx.note)

      assert Repo.aggregate(NoteLike, :count) == 0

      assert [%{"type" => "Like", "id" => like_id}, %{"type" => "Undo"} = undo] = queued()
      # The wrapped Like repeats the id the original carried, so the other
      # server drops that exact activity instead of guessing.
      assert undo["object"]["id"] == like_id
      assert undo["object"]["type"] == "Like"
    end

    test "unliking what was never liked sends nothing", ctx do
      {:ok, :unliked} = Fediverse.unlike_note(ctx.user, ctx.note)
      before = length(queued())

      assert {:ok, :already} = Fediverse.unlike_note(ctx.user, ctx.note)
      assert length(queued()) == before
    end

    test "a like → unlike → like cycle reuses one stable activity id", ctx do
      {:ok, :unliked} = Fediverse.unlike_note(ctx.user, ctx.note)
      {:ok, :liked} = Fediverse.like_note(ctx.user, ctx.note)

      ids = queued() |> Enum.filter(&(&1["type"] == "Like")) |> Enum.map(& &1["id"])
      assert [id, id] = ids
    end
  end

  describe "the gates" do
    test "a member who does not federate is told so, and nothing goes out" do
      user = insert(:activated_user)
      note = note(post_of(author()))

      assert {:error, :not_federating} = Fediverse.check_note_like(user, note)
      assert {:error, :not_federating} = Fediverse.like_note(user, note)
      assert queued() == []
    end

    test "a blocked server refuses, and its replies are gone anyway" do
      user = federating_member()
      note = note(post_of(author()), actor_uri: "https://blocked.example/users/them")

      {:ok, _} =
        Fediverse.block_instance(%{"host" => "blocked.example"}, insert(:user, admin?: true))

      # The gate says so on the struct in hand — a block shuts both directions.
      assert {:error, :instance_blocked} = Fediverse.check_note_like(user, note)
      # And the write path never gets that far, because blocking a server also
      # deletes the replies its members wrote here (`purge_instance/1`). Either
      # refusal is correct; what matters is that nothing is written or sent.
      assert {:error, :not_found} = Fediverse.like_note(user, note)
      assert Repo.aggregate(NoteLike, :count) == 0
      assert queued() == []
    end

    test "a reply with no inbox address cannot be liked at all" do
      user = federating_member()
      note = note(post_of(author()), inbox_uri: nil)

      # Replies stored before the answering feature carry no address. A marker
      # written anyway would paint a heart for a Like the author's server never
      # hears about, so the card offers none — and the write path refuses too,
      # since the id in a click is the member's to choose.
      refute Note.likeable?(note)
      assert {:error, :not_deliverable} = Fediverse.check_note_like(user, note)
      assert {:error, :not_deliverable} = Fediverse.like_note(user, note)
      assert Repo.aggregate(NoteLike, :count) == 0
      assert queued() == []
    end

    test "a private reply under somebody else's post is refused" do
      user = federating_member()
      note = note(post_of(author()), audience: "direct")

      # The id in a click is attacker-controlled, so the gate asks the same
      # question `list_notes/2` asks in SQL rather than trusting the render.
      assert {:error, :not_visible} = Fediverse.check_note_like(user, note)
      assert {:error, :not_visible} = Fediverse.like_note(user, note)
      assert Repo.aggregate(NoteLike, :count) == 0
    end

    test "answers instead of crashing when the row went between render and click" do
      user = federating_member()
      note = note(post_of(author()))
      # Expiry, an upstream Delete, a takedown or an instance block took the row
      # while the card sat on somebody's screen. The insert would otherwise hit
      # the foreign key and take the LiveView with it.
      Repo.delete!(note)

      assert {:error, :not_found} = Fediverse.like_note(user, note)
      assert Repo.aggregate(NoteLike, :count) == 0
    end

    test "the hourly budget refuses past the limit, and is the post heart's own" do
      Application.put_env(:vutuv, :fediverse_outbound_like_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_outbound_like_limit) end)

      user = federating_member()
      post = post_of(author())

      assert {:ok, :liked} = Fediverse.like_note(user, note(post))
      assert {:error, :like_capped} = Fediverse.like_note(user, note(post))
    end

    test "a capped like leaves no marker behind" do
      Application.put_env(:vutuv, :fediverse_outbound_like_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_outbound_like_limit) end)

      user = federating_member()
      post = post_of(author())
      {:ok, :liked} = Fediverse.like_note(user, note(post))

      assert {:error, :like_capped} = Fediverse.like_note(user, note(post))
      # A heart painted for a like that never left is the one disagreement a
      # member cannot fix from here, so the marker is rolled back.
      assert Repo.aggregate(NoteLike, :count) == 1
    end

    test "a repeat that sends nothing does not spend a slot" do
      Application.put_env(:vutuv, :fediverse_outbound_like_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_outbound_like_limit) end)

      user = federating_member()
      note = note(post_of(author()))

      assert {:ok, :liked} = Fediverse.like_note(user, note)
      assert {:ok, :already} = Fediverse.like_note(user, note)
      assert length(queued()) == 1
    end

    test "taking a like back is never refused by the budget" do
      user = federating_member()
      post = post_of(author())
      note = note(post)
      {:ok, :liked} = Fediverse.like_note(user, note)

      Application.put_env(:vutuv, :fediverse_outbound_like_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_outbound_like_limit) end)
      {:error, :like_capped} = Fediverse.like_note(user, note(post))

      assert {:ok, :unliked} = Fediverse.unlike_note(user, note)
    end
  end

  describe "leaving the Fediverse" do
    test "withdraws every like on a reply and drops the markers" do
      user = federating_member()
      note = note(post_of(author()))
      {:ok, :liked} = Fediverse.like_note(user, note)

      assert Fediverse.drop_note_likes(user) == 1

      assert Repo.aggregate(NoteLike, :count) == 0
      # What stood on another server under their name goes with the decision
      # rather than after it.
      assert [%{"type" => "Like"}, %{"type" => "Undo"}] = queued()
    end

    test "switching Fediverse participation off takes them with it" do
      user = federating_member()
      {:ok, :liked} = Fediverse.like_note(user, note(post_of(author())))

      # The rows about people on other networks go in both directions, and a
      # note like hangs off no follow, so nothing else would ever take it.
      Fediverse.drop_remote_follows(user)

      assert Repo.aggregate(NoteLike, :count) == 0
      assert Enum.any?(queued(), &(&1["type"] == "Undo"))
    end
  end

  describe "the reply going away" do
    test "takes its likes with it, without leaving an orphan" do
      user = federating_member()
      note = note(post_of(author()))
      {:ok, :liked} = Fediverse.like_note(user, note)

      Repo.delete!(note)

      # Our copy is a six-month cache; the like on the author's server is not
      # ours to keep alive, so the row cascades rather than dangling.
      assert Repo.aggregate(NoteLike, :count) == 0
    end
  end

  describe "the GDPR export" do
    test "lists a liked reply as the member's own act" do
      user = federating_member()
      note = note(post_of(author()))
      {:ok, :liked} = Fediverse.like_note(user, note)

      assert [entry] = Vutuv.Export.build(user).fediverse_likes

      assert entry.kind == "reply"
      assert entry.post == note.origin_url
      assert entry.author == "@them@social.example"
      assert entry.server == "social.example"
    end
  end
end
