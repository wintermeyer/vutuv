defmodule Vutuv.PostsRemoteRepliesTest do
  @moduledoc """
  Answering a reply that came from another network (issue #1070).

  async: false — the outbound reply budget lives in the shared
  `Vutuv.RateLimiter` ETS table, which the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.Note
  alias Vutuv.Posts
  alias Vutuv.Posts.PostRemoteReply

  @actor "https://social.example/users/alice"
  @inbox "https://social.example/users/alice/inbox"

  setup do
    Vutuv.RateLimiter.reset()

    author = insert(:activated_user, fediverse_followers?: true, fediverse_replies?: true)
    post = create_post!(author, %{"body" => "Federated far and wide."})

    {:ok, author: author, post: post, note: insert_note!(post)}
  end

  # A stored public reply from another network, the way the inbox writes one.
  defp insert_note!(post, attrs \\ %{}) do
    now = DateTime.utc_now(:second)

    %Note{post_id: post.id}
    |> Note.changeset(
      Map.merge(
        %{
          object_uri: "#{@actor}/statuses/#{System.unique_integer([:positive])}",
          actor_uri: @actor,
          inbox_uri: @inbox,
          handle: "alice",
          display_name: "Alice Anders",
          content_text: "Guter Punkt.",
          audience: "public",
          received_at: now,
          checked_at: now,
          expires_at: DateTime.add(now, 183 * 86_400)
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "create_remote_reply/3" do
    test "creates an ordinary reply plus the sidecar naming what it answers", %{
      author: author,
      post: post,
      note: note
    } do
      assert {:ok, reply} =
               Posts.create_remote_reply(author, note, %{"body" => "Danke, freut mich!"})

      # Underneath it is a normal reply to the vutuv post, so local threading,
      # the reply count and the edit window are untouched.
      reply = Repo.preload(reply, [:reply_ref, :remote_reply_ref])
      assert reply.reply_ref.parent_post_id == post.id
      assert reply.reply_ref.parent_author_id == author.id

      # On top, the record of the other thing it answers.
      assert %PostRemoteReply{} = ref = reply.remote_reply_ref
      assert ref.note_id == note.id
      assert ref.in_reply_to_uri == note.object_uri
      assert ref.actor_uri == @actor
      assert ref.inbox_uri == @inbox
      assert ref.handle == "@alice@social.example"
    end

    test "a member who is not the post's author may answer too", %{note: note} do
      stranger = insert(:activated_user, fediverse_followers?: true)

      assert {:ok, reply} =
               Posts.create_remote_reply(stranger, note, %{"body" => "Sehe ich auch so."})

      assert reply.user_id == stranger.id
    end

    test "keeps the delivery target after the note is collected", %{author: author, note: note} do
      assert {:ok, reply} = Posts.create_remote_reply(author, note, %{"body" => "Bis bald."})

      # The note is a cache: it expires six months out, or a takedown removes it.
      Repo.delete!(note)

      ref = Repo.get_by!(PostRemoteReply, post_id: reply.id)
      # note_id nilifies, but everything an Update/Delete needs is still here.
      assert is_nil(ref.note_id)
      assert ref.in_reply_to_uri
      assert ref.actor_uri == @actor
      assert ref.inbox_uri == @inbox
    end
  end

  describe "create_remote_reply/3 — the gates" do
    test "refuses a member who has not switched federation on", %{note: note} do
      plain = insert(:activated_user)

      assert {:error, :not_federating} =
               Posts.create_remote_reply(plain, note, %{"body" => "Hallo"})

      assert [] = Repo.all(PostRemoteReply)
    end

    test "refuses a reply that was addressed to the member alone", %{author: author, post: post} do
      private = insert_note!(post, %{audience: "direct"})

      assert {:error, :note_not_public} =
               Posts.create_remote_reply(author, private, %{"body" => "Hallo"})
    end

    test "refuses a member who moved their account away", %{author: author, note: note} do
      {:ok, moved} =
        author
        |> Ecto.Changeset.change(moved_to: "https://elsewhere.example/users/a")
        |> Repo.update()

      assert {:error, :moved} = Posts.create_remote_reply(moved, note, %{"body" => "Hallo"})
    end

    test "refuses once the operator blocked that server", %{author: author, note: note} do
      admin = insert(:activated_user)
      {:ok, _blocked} = Fediverse.block_instance(%{"host" => "social.example"}, admin)

      # A block is both ears and mouth shut, so it stops answers going out too.
      assert {:error, :instance_blocked} =
               Posts.create_remote_reply(author, note, %{"body" => "Hallo"})
    end

    test "refuses past the member's hourly budget", %{author: author, post: post} do
      # One slot, so the second answer is over budget whatever the default is.
      Application.put_env(:vutuv, :fediverse_outbound_reply_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_outbound_reply_limit) end)

      assert {:ok, _first} =
               Posts.create_remote_reply(author, insert_note!(post), %{"body" => "Eins"})

      assert {:error, :reply_capped} =
               Posts.create_remote_reply(author, insert_note!(post), %{"body" => "Zwei"})
    end

    test "refuses while the installation switch is off", %{author: author, note: note} do
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.put_env(:vutuv, :fediverse_enabled, true) end)

      assert {:error, :fediverse_disabled} =
               Posts.create_remote_reply(author, note, %{"body" => "Hallo"})
    end
  end

  describe "what leaves for the other network" do
    setup %{author: author} do
      {:ok, _actor} = Fediverse.ensure_actor(author)

      {:ok, _follower} =
        Fediverse.add_follower(author, %{
          actor_uri: "https://follower.example/users/f",
          inbox_uri: "https://follower.example/inbox"
        })

      :ok
    end

    test "reaches the answered person's inbox as well as the member's followers", %{
      author: author,
      note: note
    } do
      assert {:ok, _reply} = Posts.create_remote_reply(author, note, %{"body" => "Danke!"})

      inboxes = Delivery |> Repo.all() |> Enum.map(& &1.inbox_uri) |> Enum.sort()
      assert inboxes == ["https://follower.example/inbox", @inbox]
    end

    test "carries inReplyTo into the other network and a Mention of its author", %{
      author: author,
      note: note
    } do
      assert {:ok, _reply} = Posts.create_remote_reply(author, note, %{"body" => "Danke!"})

      activity =
        Delivery
        |> Repo.all()
        |> Enum.find(&(&1.inbox_uri == @inbox))
        |> Map.fetch!(:activity_json)
        |> Jason.decode!()

      object = activity["object"]
      # The answer points at the remote note, not at the vutuv post underneath:
      # that note already points back at our post, so this is what threads the
      # answer correctly on the other server.
      assert object["inReplyTo"] == note.object_uri

      # The Mention is what makes them notified. Built from the stored actor URI.
      assert [%{"type" => "Mention", "href" => @actor, "name" => "@alice@social.example"}] =
               object["tag"]

      # Addressed to them by name on top of the usual public audience.
      assert @actor in object["cc"]
      assert object["to"] == ["https://www.w3.org/ns/activitystreams#Public"]

      # The handle is written into the outgoing HTML the way these networks do,
      # linked to the actor.
      assert object["content"] =~
               ~s(<a href="#{@actor}" class="u-url mention">@alice@social.example</a>)

      assert object["content"] =~ "Danke!"
    end

    test "the member's own stored body never carries the foreign handle", %{
      author: author,
      note: note
    } do
      assert {:ok, reply} = Posts.create_remote_reply(author, note, %{"body" => "Danke!"})

      # On vutuv the answer shows a "Replying to" line instead, so a member who
      # has never heard of Mastodon does not type handles in a foreign format.
      assert reply.body == "Danke!"
      refute reply.body =~ "@alice"
    end

    test "still reaches the answered person when the member has no followers", %{note: note} do
      lonely = insert(:activated_user, fediverse_followers?: true)
      {:ok, _actor} = Fediverse.ensure_actor(lonely)

      assert {:ok, _reply} = Posts.create_remote_reply(lonely, note, %{"body" => "Auch von mir."})

      assert [%Delivery{inbox_uri: @inbox}] = Repo.all(Delivery)
    end

    test "deleting the answer tells the answered person too", %{author: author, note: note} do
      assert {:ok, reply} = Posts.create_remote_reply(author, note, %{"body" => "Danke!"})
      Repo.delete_all(Delivery)

      assert {:ok, _deleted} = Posts.delete_post(reply)

      deliveries = Repo.all(Delivery)
      assert @inbox in Enum.map(deliveries, & &1.inbox_uri)

      activity = deliveries |> Enum.find(&(&1.inbox_uri == @inbox)) |> Map.fetch!(:activity_json)
      assert activity =~ ~s("type":"Delete")
    end

    test "an answer whose note carried no usable inbox goes to followers only", %{
      author: author,
      post: post
    } do
      # A note stored before issue #1070, or one whose server named an inbox it
      # does not control (own_inbox/1 refused it).
      note = insert_note!(post, %{inbox_uri: nil})

      assert {:ok, _reply} = Posts.create_remote_reply(author, note, %{"body" => "Hallo"})

      assert [%Delivery{inbox_uri: "https://follower.example/inbox"}] = Repo.all(Delivery)
    end
  end
end
