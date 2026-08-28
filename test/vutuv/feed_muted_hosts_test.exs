defmodule Vutuv.FeedMutedHostsTest do
  @moduledoc """
  The feed filter band's two stored decisions: whole fediverse servers switched
  off (`users.feed_muted_hosts`) and how the band itself is arranged
  (`users.feed_rail`).

  Muting a server is the instance-level twin of `fediverse_follows.muted`: the
  follow stays, the posts go. The feed sources are what has to honour it, so
  these tests go through `Vutuv.Posts.feed_page/2` rather than asking the list
  back — a list that is stored and never read would pass a happier test.

  `async: false` — the inbound caps live in the shared `Vutuv.RateLimiter` ETS
  table, which the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Posts

  @actor "https://social.example/users/them"
  @other_actor "https://elsewhere.example/users/other"
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

  defp follow(user, account) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      muted: false,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
    })
  end

  defp post_from(actor, id, text) do
    :ok =
      Fediverse.record_remote_post(
        %{
          "type" => "Create",
          "actor" => actor,
          "object" => %{
            "id" => actor <> "/posts/#{id}",
            "type" => "Note",
            "attributedTo" => actor,
            "content" => "<p>#{text}</p>",
            "published" => "2026-07-20T10:00:00Z",
            "to" => [@public]
          }
        },
        actor
      )
  end

  defp reload(user), do: Repo.get!(User, user.id)

  describe "switching a server off" do
    setup do
      user = insert(:activated_user, fediverse_followers?: true)
      them = account("social.example", @actor, "them")
      other = account("elsewhere.example", @other_actor, "other")
      follow(user, them)
      follow(user, other)
      post_from(@actor, 1, "From the muted server.")
      post_from(@other_actor, 2, "From the other one.")

      %{user: user, them: them}
    end

    test "starts empty and takes the host", %{user: user} do
      assert Fediverse.muted_hosts(user) == []

      {:ok, hosts} = Fediverse.set_host_mute(user, "social.example", true)

      assert hosts == ["social.example"]
      assert Fediverse.muted_hosts(reload(user)) == ["social.example"]
    end

    test "normalises what the panel hands over", %{user: user} do
      {:ok, hosts} = Fediverse.set_host_mute(user, "  Social.Example  ", true)

      assert hosts == ["social.example"]
    end

    test "muting twice does not grow the list, unmuting empties it", %{user: user} do
      {:ok, _} = Fediverse.set_host_mute(user, "social.example", true)
      {:ok, hosts} = Fediverse.set_host_mute(reload(user), "social.example", true)
      assert hosts == ["social.example"]

      {:ok, hosts} = Fediverse.set_host_mute(reload(user), "social.example", false)
      assert hosts == []
    end

    test "its posts leave the feed, the other server's stay", %{user: user} do
      assert texts(user) == ["From the other one.", "From the muted server."]

      {:ok, _} = Fediverse.set_host_mute(user, "social.example", true)

      assert texts(reload(user)) == ["From the other one."]
    end

    test "the follow itself is untouched, so switching back on restores it", %{
      user: user,
      them: them
    } do
      {:ok, _} = Fediverse.set_host_mute(user, "social.example", true)

      follow = Repo.get_by!(Follow, user_id: user.id, remote_account_id: them.id)
      assert follow.muted == false
      assert follow.state == "accepted"

      {:ok, _} = Fediverse.set_host_mute(reload(user), "social.example", false)
      assert "From the muted server." in texts(reload(user))
    end
  end

  defp texts(user) do
    user
    |> Posts.feed_page()
    |> Map.fetch!(:entries)
    |> Enum.filter(&Posts.remote_feed_entry?/1)
    |> Enum.map(& &1.remote_post.content_text)
  end

  describe "the band's arrangement" do
    @blocks [:live, :accounts, :topics, :words, :tags, :off]

    test "an untouched member gets the shipped order, folds and all" do
      user = insert(:user)

      assert Posts.feed_rail(user, @blocks, [:tags, :off]) == %{
               order: ~w(live accounts topics words tags off),
               collapsed: ~w(tags off),
               removed: []
             }
    end

    # The shipped folds are for somebody opening the rail for the first time.
    # A member who has arranged it has already decided what stands open, and
    # re-folding a card they chose to leave open every time the default moves
    # would read as the page undoing their work.
    test "the shipped folds do not reach a member who has arranged the rail" do
      user = insert(:user)

      {:ok, _} =
        Posts.save_feed_rail(user, %{
          order: ~w(live accounts topics words tags off),
          collapsed: [],
          removed: []
        })

      assert %{collapsed: []} = Posts.feed_rail(reload(user), @blocks, [:tags, :off])
    end

    test "a stored arrangement comes back" do
      user = insert(:user)

      {:ok, _} =
        Posts.save_feed_rail(user, %{
          order: ~w(words live accounts topics tags off),
          collapsed: ["accounts"],
          removed: ["tags"]
        })

      assert %{order: order, collapsed: ["accounts"], removed: ["tags"]} =
               Posts.feed_rail(reload(user), @blocks)

      assert order == ~w(words live accounts topics tags off)
    end

    test "a block that shipped later lands at the end, a retired one is dropped" do
      user = insert(:user)

      {:ok, _} =
        Posts.save_feed_rail(user, %{
          order: ~w(retired words live),
          collapsed: ["retired"],
          removed: []
        })

      assert %{order: order, collapsed: []} = Posts.feed_rail(reload(user), @blocks)
      assert Enum.take(order, 2) == ~w(words live)
      assert Enum.sort(order) == Enum.sort(~w(live accounts topics words tags off))
    end
  end
end
