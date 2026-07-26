defmodule Vutuv.FediverseReactionsTest do
  @moduledoc """
  What other networks did with a member's post (issue #1068): the counter rows
  behind the "reactions from other networks" line.

  async: false — the inbound caps (issue #1067) live in the shared
  `Vutuv.RateLimiter` ETS table, which the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Accounts
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Reaction
  alias Vutuv.Posts
  alias VutuvWeb.Fediverse.Docs

  @actor "https://social.example/users/alice"
  @other_actor "https://social.example/users/bob"

  setup do
    Vutuv.RateLimiter.reset()
    user = insert(:activated_user, fediverse_followers?: true)
    post = create_post!(user, %{"body" => "Federated far and wide."})
    {:ok, user: user, post: post, note: Docs.note_url(user, post.id)}
  end

  describe "record_reaction/4" do
    test "counts a Like once per remote person", %{user: user, post: post, note: note} do
      assert :ok = Fediverse.record_reaction(user, note, "like", @actor)
      assert :ok = Fediverse.record_reaction(user, note, "like", @actor)
      assert Fediverse.reaction_count(post.id) == 1

      assert :ok = Fediverse.record_reaction(user, note, "like", @other_actor)
      assert Fediverse.reaction_count(post.id) == 2
    end

    test "a Like and an Announce from the same person are two reactions", %{
      user: user,
      post: post,
      note: note
    } do
      assert :ok = Fediverse.record_reaction(user, note, "like", @actor)
      assert :ok = Fediverse.record_reaction(user, note, "announce", @actor)

      assert Fediverse.reaction_count(post.id) == 2
    end

    test "accepts an embedded object as well as a bare URL", %{user: user, post: post, note: note} do
      assert :ok = Fediverse.record_reaction(user, %{"id" => note}, "like", @actor)
      assert Fediverse.reaction_count(post.id) == 1
    end

    test "stores nothing but the account address, the kind and when it arrived", %{
      user: user,
      post: post,
      note: note
    } do
      :ok = Fediverse.record_reaction(user, note, "like", @actor)

      assert [%Reaction{} = row] = Repo.all(Reaction)
      assert row.post_id == post.id
      assert row.actor_uri == @actor
      assert row.kind == "like"
      assert row.received_at
      # The whole schema: an account address in two notations, and what they
      # did. Still no display name, no avatar, no text about a third party.
      assert Reaction.__schema__(:fields) ==
               [:id, :actor_uri, :handle, :kind, :received_at, :post_id]
    end

    test "keeps the handle the inbox already fetched, so the post can name them", %{
      user: user,
      note: note
    } do
      assert :ok =
               Fediverse.record_reaction(user, note, "announce", %{
                 uri: @actor,
                 handle: "alice"
               })

      assert [%Reaction{} = row] = Repo.all(Reaction)
      assert row.actor_uri == @actor
      assert row.handle == "alice"
      assert Reaction.display_handle(row) == "@alice@social.example"
    end

    test "names them from the actor URI when the server sent no preferredUsername", %{
      user: user,
      note: note
    } do
      assert :ok = Fediverse.record_reaction(user, note, "like", %{uri: @actor, handle: nil})

      assert [%Reaction{handle: nil} = row] = Repo.all(Reaction)
      assert Reaction.display_handle(row) == "@alice@social.example"
    end

    test "a hostile handle is cut to a column's worth, and the reaction still counts", %{
      user: user,
      post: post,
      note: note
    } do
      assert :ok =
               Fediverse.record_reaction(user, note, "like", %{
                 uri: @actor,
                 handle: String.duplicate("a", 300)
               })

      assert [%Reaction{handle: handle}] = Repo.all(Reaction)
      assert String.length(handle) == 255
      assert Fediverse.reaction_count(post.id) == 1
    end

    test "ignores a post that is not the addressed member's", %{note: note} do
      stranger = insert(:activated_user, fediverse_followers?: true)

      assert :skip = Fediverse.record_reaction(stranger, note, "like", @actor)
      assert Repo.aggregate(Reaction, :count) == 0
    end

    test "ignores anything that is not one of our Note URLs", %{user: user} do
      for object <- [
            "https://social.example/users/alice/statuses/1",
            "#{VutuvWeb.Endpoint.url()}/#{user.username}/posts/not-a-uuid",
            "#{VutuvWeb.Endpoint.url()}/#{user.username}",
            nil,
            42
          ] do
        assert :skip = Fediverse.record_reaction(user, object, "like", @actor)
      end

      assert Repo.aggregate(Reaction, :count) == 0
    end

    test "ignores a non-public post", %{user: user} do
      restricted =
        create_post!(user, %{
          body: "Just for some.",
          denials: [%{"wildcard" => "logged_out"}]
        })

      assert :skip =
               Fediverse.record_reaction(
                 user,
                 Docs.note_url(user, restricted.id),
                 "like",
                 @actor
               )

      assert Repo.aggregate(Reaction, :count) == 0
    end

    test "ignores a member who does not federate", %{note: note} do
      plain = insert(:activated_user)

      assert :skip = Fediverse.record_reaction(plain, note, "like", @actor)
      assert Repo.aggregate(Reaction, :count) == 0
    end

    test "ignores a member who switched the counts off", %{user: user, note: note} do
      {:ok, user} = Accounts.update_user(user, %{"fediverse_reactions?" => false})

      assert :skip = Fediverse.record_reaction(user, note, "like", @actor)
      assert Repo.aggregate(Reaction, :count) == 0
    end

    test "stores nothing while federation is switched off installation-wide", %{
      user: user,
      note: note
    } do
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      assert :skip = Fediverse.record_reaction(user, note, "like", @actor)
      assert Repo.aggregate(Reaction, :count) == 0
    end

    test "is subject to the inbound caps (#1067)", %{user: user, note: note} do
      Application.put_env(:vutuv, :fediverse_inbound_caps, {1, 1})
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_inbound_caps) end)

      assert :ok = Fediverse.record_reaction(user, note, "like", @actor)
      assert :skip = Fediverse.record_reaction(user, note, "announce", @other_actor)
    end
  end

  describe "remove_reaction/4" do
    test "an Undo takes exactly that reaction back", %{user: user, post: post, note: note} do
      :ok = Fediverse.record_reaction(user, note, "like", @actor)
      :ok = Fediverse.record_reaction(user, note, "announce", @actor)

      assert :ok = Fediverse.remove_reaction(user, note, "like", @actor)

      assert [%Reaction{kind: "announce"}] = Repo.all(Reaction)
      assert Fediverse.reaction_count(post.id) == 1
    end

    test "is honoured even after the member switched the counts off", %{
      user: user,
      post: post,
      note: note
    } do
      :ok = Fediverse.record_reaction(user, note, "like", @actor)
      {:ok, user} = Accounts.update_user(user, %{"fediverse_reactions?" => false})

      assert :ok = Fediverse.remove_reaction(user, note, "like", @actor)
      assert Fediverse.reaction_count(post.id) == 0
    end
  end

  describe "cascades" do
    test "deleting the post takes its reactions", %{user: user, post: post, note: note} do
      :ok = Fediverse.record_reaction(user, note, "like", @actor)

      {:ok, _} = Posts.delete_post(post)

      assert Repo.aggregate(Reaction, :count) == 0
    end

    test "deleting the account takes them too", %{user: user, note: note} do
      :ok = Fediverse.record_reaction(user, note, "like", @actor)

      {:ok, _} = Accounts.delete_user(user)

      assert Repo.aggregate(Reaction, :count) == 0
    end

    test "switching the counts off drops what is stored", %{user: user, note: note} do
      :ok = Fediverse.record_reaction(user, note, "like", @actor)

      assert Fediverse.drop_reactions(user) == 1
      assert Repo.aggregate(Reaction, :count) == 0
    end
  end

  describe "the author hears about it" do
    test "a new reaction pushes a notification naming the account and the verb", %{
      user: user,
      post: post,
      note: note
    } do
      Vutuv.Activity.subscribe(user.id)

      :ok = Fediverse.record_reaction(user, note, "announce", %{uri: @actor, handle: "alice"})

      assert_receive {:new_notification, n}
      assert n.kind == "fediverse_reaction"
      assert n.reaction_kind == "announce"
      assert n.post_id == post.id
      assert n.actor_handle == "@alice@social.example"
      # A stranger with no vutuv profile: linked out to, never into a profile
      # route that does not exist.
      assert n.actor_url == @actor
      assert n.actor_param == nil
      assert n.actor_avatar == nil
    end

    test "a redelivery of the same reaction does not ring twice", %{user: user, note: note} do
      :ok = Fediverse.record_reaction(user, note, "like", @actor)

      Vutuv.Activity.subscribe(user.id)
      :ok = Fediverse.record_reaction(user, note, "like", @actor)

      refute_receive {:new_notification, _}
    end

    test "it joins the derived feed and the unread badge", %{user: user, post: post, note: note} do
      :ok = Fediverse.record_reaction(user, note, "announce", %{uri: @actor, handle: "alice"})

      assert Vutuv.Activity.unread_notification_count(user.id) == 1

      assert %{entries: [entry]} =
               Vutuv.Activity.notifications_page(user.id, kinds: ["fediverse_reaction"])

      assert entry.kind == "fediverse_reaction"
      assert entry.reaction_kind == "announce"
      assert entry.post_id == post.id
      assert entry.actor_handle == "@alice@social.example"
    end

    test "taking the reaction back takes its notification with it", %{user: user, note: note} do
      :ok = Fediverse.record_reaction(user, note, "like", @actor)
      :ok = Fediverse.remove_reaction(user, note, "like", @actor)

      # The whole point of deriving the feed from the reaction rows: there is no
      # second place that has to remember to forget.
      assert Vutuv.Activity.unread_notification_count(user.id) == 0
      assert %{entries: []} = Vutuv.Activity.notifications_page(user.id)
    end
  end

  describe "the count reaches the action bar" do
    test "engagement_counts/1 carries it beside the vutuv counters", %{
      user: user,
      post: post,
      note: note
    } do
      assert Posts.engagement_counts(post.id).fediverse_reactions == 0

      :ok = Fediverse.record_reaction(user, note, "like", @actor)

      counts = Posts.engagement_counts(post.id)
      assert counts.fediverse_reactions == 1
      # Never folded into the vutuv figures: a hostile remote server may only
      # inflate its own line.
      assert counts.likes == 0
      assert counts.reposts == 0
    end

    test "post_engagement/2 carries it too", %{user: user, post: post, note: note} do
      :ok = Fediverse.record_reaction(user, note, "like", @actor)

      assert Posts.post_engagement(post.id, nil).fediverse_reactions == 1
    end

    test "and the accounts behind it, newest first and capped", %{
      user: user,
      post: post,
      note: note
    } do
      for n <- 1..6 do
        :ok =
          Fediverse.record_reaction(user, note, "announce", %{
            uri: "https://social.example/users/fan#{n}",
            handle: "fan#{n}"
          })
      end

      counts = Posts.engagement_counts(post.id)

      # The count stays the true total; only the named rows are capped, so the
      # card can render "and N more" without a second query.
      assert counts.fediverse_reactions == 6
      assert length(counts.fediverse_reaction_actors) == 4

      assert [%{"handle" => "fan6", "kind" => "announce"} | _] =
               counts.fediverse_reaction_actors
    end
  end
end
