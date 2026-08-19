defmodule Vutuv.FediverseRemoteEngagementTest do
  @moduledoc """
  Resharing a reply from another network (issue #1275) and saving either kind of
  thing from one (issue #1276).

  The point of this file is the **pairing**: a cached post and a reply are the
  same object to a reader, so a claim that holds for one and not the other is
  drift. Each describe block therefore asks the same question of both.

  `async: false` — the outbound budget lives in the shared `Vutuv.RateLimiter`
  ETS table, which the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Bookmark
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.NoteRepost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  @actor "https://social.example/users/them"
  @inbox "https://social.example/users/them/inbox"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp federating_member do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    Repo.reload!(user)
  end

  defp note(attrs \\ []) do
    now = DateTime.utc_now(:second)
    post = insert(:post, user: attrs[:author] || insert(:activated_user))

    Repo.insert!(%Note{
      post_id: post.id,
      object_uri: "https://social.example/n/#{System.unique_integer([:positive])}",
      actor_uri: @actor,
      origin_url: "https://social.example/@them/1",
      handle: "them",
      display_name: "Thea Remote",
      content_text: attrs[:content_text] || "Etwas Lesenswertes.",
      audience: attrs[:audience] || "public",
      inbox_uri: @inbox,
      received_at: now,
      checked_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
  end

  defp cached_post(audience \\ "public") do
    now = DateTime.utc_now(:second)

    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: @actor,
        host: "social.example",
        handle: "them",
        inbox_uri: @inbox
      })

    Repo.insert!(%RemotePost{
      remote_account_id: account.id,
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

  defp queued do
    from(d in Delivery, order_by: [asc: d.id])
    |> Repo.all()
    |> Enum.map(&Jason.decode!(&1.activity_json))
  end

  describe "resharing a reply" do
    test "writes the row and queues a signed Announce to the reader's own followers" do
      user = federating_member()
      note = note()

      assert {:ok, :reposted} = Fediverse.repost_note(user, note)

      assert Repo.aggregate(NoteRepost, :count) == 1
      assert [%{"type" => "Announce", "object" => object}] = queued()
      assert object == note.object_uri
    end

    test "resharing twice is one row and one activity" do
      user = federating_member()
      note = note()

      assert {:ok, :reposted} = Fediverse.repost_note(user, note)
      assert {:ok, :already} = Fediverse.repost_note(user, note)

      assert Repo.aggregate(NoteRepost, :count) == 1
      assert length(queued()) == 1
    end

    test "taking it back drops the row and queues the matching Undo" do
      user = federating_member()
      note = note()
      {:ok, :reposted} = Fediverse.repost_note(user, note)

      assert {:ok, :unreposted} = Fediverse.unrepost_note(user, note)

      assert Repo.aggregate(NoteRepost, :count) == 0
      assert [%{"type" => "Announce", "id" => id}, %{"type" => "Undo"} = undo] = queued()
      assert undo["object"]["id"] == id
    end

    test "a reply its author sent to one person cannot be passed on" do
      user = federating_member()
      note = note(audience: "direct", author: user)

      # The reader may *like* it — that is addressed to its author alone — but a
      # reshare hands it to everybody, and the audience its author chose is not
      # ours to widen.
      assert :ok = Fediverse.check_note_like(user, note)
      assert {:error, :note_not_public} = Fediverse.check_note_repost(user, note)
      assert {:error, :note_not_public} = Fediverse.repost_note(user, note)
      assert queued() == []
    end

    test "a member who does not federate is told so, and nothing goes out" do
      user = insert(:activated_user)

      assert {:error, :not_federating} = Fediverse.repost_note(user, note())
      assert queued() == []
    end

    test "leaving the Fediverse withdraws it" do
      user = federating_member()
      {:ok, :reposted} = Fediverse.repost_note(user, note())

      Fediverse.drop_remote_follows(user)

      assert Repo.aggregate(NoteRepost, :count) == 0
      assert Enum.any?(queued(), &(&1["type"] == "Undo"))
    end

    test "it reaches the feed of somebody who follows the resharer here" do
      resharer = federating_member()
      reader = insert(:activated_user)
      {:ok, _} = Vutuv.Social.follow(reader, resharer.id)
      note = note()

      {:ok, :reposted} = Fediverse.repost_note(resharer, note)

      assert [entry] = Fediverse.feed_remote_reply_reposts(reader, 10, nil)
      assert entry.note.id == note.id
      assert entry.reposted_by.id == resharer.id
      # What is new is the sharing, so the row is stamped with it.
      assert entry.post == nil
      assert Vutuv.Posts.remote_reply_entry?(entry)
      assert Vutuv.Posts.remote_feed_entry?(entry)
    end

    test "and the feed page it lands on renders it" do
      resharer = federating_member()
      reader = insert(:activated_user)
      {:ok, _} = Vutuv.Social.follow(reader, resharer.id)

      {:ok, :reposted} = Fediverse.repost_note(resharer, note())

      # Not the source alone: `Vutuv.Posts.decorate_feed_entries/2` treats every
      # remote entry as a cached post and reaches for `entry.remote_post`, which
      # a reshared reply does not have. That raised a KeyError, so the whole feed
      # 500ed for anybody one of their followees had passed a reply on to.
      assert %{entries: entries} = Vutuv.Posts.feed_page(reader)
      assert Enum.any?(entries, &Vutuv.Posts.remote_reply_entry?/1)
    end

    test "it does not reach somebody who follows nobody involved" do
      resharer = federating_member()
      stranger = insert(:activated_user)
      {:ok, :reposted} = Fediverse.repost_note(resharer, note())

      assert Fediverse.feed_remote_reply_reposts(stranger, 10, nil) == []
    end
  end

  describe "saving either kind of thing" do
    test "a reply and a cached post both land in one list, newest saved first" do
      user = federating_member()
      note = note()
      post = cached_post()

      assert {:ok, :bookmarked} = Fediverse.bookmark_note(user, note)
      assert {:ok, :bookmarked} = Fediverse.bookmark_remote_post(user, post)

      assert [first, second] = Fediverse.saved_from_networks(user)
      assert first.remote_post.id == post.id
      assert second.note.id == note.id
      assert Repo.aggregate(Bookmark, :count) == 2
    end

    test "nothing is sent for either — a bookmark stays here" do
      user = federating_member()

      {:ok, :bookmarked} = Fediverse.bookmark_note(user, note())
      {:ok, :bookmarked} = Fediverse.bookmark_remote_post(user, cached_post())

      assert queued() == []
    end

    test "a member who does not federate at all may still save" do
      # The one act on these cards that asks nothing of a member's standing: no
      # actor is needed because nothing is signed.
      user = insert(:activated_user)

      assert {:ok, :bookmarked} = Fediverse.bookmark_note(user, note())
      assert {:ok, :bookmarked} = Fediverse.bookmark_remote_post(user, cached_post())
    end

    test "saving twice is one row, and taking it back drops it" do
      user = federating_member()
      note = note()

      assert {:ok, :bookmarked} = Fediverse.bookmark_note(user, note)
      assert {:ok, :already} = Fediverse.bookmark_note(user, note)
      assert Repo.aggregate(Bookmark, :count) == 1

      assert {:ok, :unbookmarked} = Fediverse.unbookmark_note(user, note)
      assert {:ok, :already} = Fediverse.unbookmark_note(user, note)
      assert Repo.aggregate(Bookmark, :count) == 0
    end

    test "what a member may not read, they may not save" do
      user = federating_member()

      assert {:error, :not_visible} = Fediverse.bookmark_note(user, note(audience: "direct"))

      assert {:error, :not_visible} =
               Fediverse.bookmark_remote_post(user, cached_post("followers"))

      assert Repo.aggregate(Bookmark, :count) == 0
    end

    test "the list can be searched by what was said and by who said it" do
      user = federating_member()
      {:ok, :bookmarked} = Fediverse.bookmark_note(user, note(content_text: "Über Fahrräder."))
      {:ok, :bookmarked} = Fediverse.bookmark_remote_post(user, cached_post())

      assert [entry] = Fediverse.saved_from_networks(user, q: "Fahrräder")
      assert entry.note.content_text == "Über Fahrräder."

      assert length(Fediverse.saved_from_networks(user, q: "them")) == 2
      assert Fediverse.saved_from_networks(user, q: "nothing like this") == []
    end

    test "it goes with the thing it points at" do
      user = federating_member()
      note = note()
      {:ok, :bookmarked} = Fediverse.bookmark_note(user, note)

      Repo.delete!(note)

      # Our copy is a six-month cache; a pointer to something we no longer hold
      # is not something to keep.
      assert Repo.aggregate(Bookmark, :count) == 0
    end
  end

  describe "the marks a page batches" do
    test "one lookup answers all three for a mixed page" do
      user = federating_member()
      note = note()
      post = cached_post()

      {:ok, :liked} = Fediverse.like_note(user, note)
      {:ok, :bookmarked} = Fediverse.bookmark_remote_post(user, post)

      marks = Fediverse.mark_lookup([note, post], user)

      assert marks.(note) == %{liked?: true, reposted?: false, bookmarked?: false}
      assert marks.(post) == %{liked?: false, reposted?: false, bookmarked?: true}
    end

    test "a logged-out reader has done none of it, and asking does not blow up" do
      marks = Fediverse.mark_lookup([note(), cached_post()], nil)

      assert marks.(note()) == %{liked?: false, reposted?: false, bookmarked?: false}
    end
  end
end
