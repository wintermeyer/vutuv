defmodule Vutuv.FediverseBlocklistTest do
  @moduledoc """
  The operator's blocklist and the inbound caps (issue #1067): the safety floor
  under everything a remote server sends us.

  async: false — the inbound caps live in the shared `Vutuv.RateLimiter` ETS
  table, which the SQL sandbox does not roll back, so a parallel module hitting
  the same host bucket would make these counts drift.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.ExternalTagHelpers, only: [external_post: 2]

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.BlockedInstance
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.Follower
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.PostDelivery
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Tags.ExternalPost
  alias Vutuv.UUIDv7

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp admin, do: insert(:activated_user, admin?: true)

  defp federating_member do
    insert(:activated_user, fediverse_followers?: true)
  end

  # One row in each table a block purges by host, all naming `host`.
  defp store_everywhere(member, host) do
    actor = "https://#{host}/users/bot"
    inbox = "https://#{host}/inbox"

    {:ok, _} = Fediverse.add_follower(member, %{actor_uri: actor, inbox_uri: inbox})

    %RemoteAccount{}
    |> RemoteAccount.changeset(%{actor_uri: actor, host: host, handle: "bot", inbox_uri: inbox})
    |> Repo.insert!()

    insert(:note, actor_uri: actor, inbox_uri: inbox)

    Repo.insert!(%Delivery{
      user_id: member.id,
      inbox_uri: inbox,
      activity_json: "{}",
      attempts: 0,
      next_attempt_at: DateTime.utc_now(:second)
    })

    Repo.insert!(%PostDelivery{
      post_id: UUIDv7.generate(),
      user_id: member.id,
      inbox_uri: inbox,
      object_uri: "https://vutuv.example/posts/#{System.unique_integer([:positive])}"
    })

    # A tag find names a server twice: the one that filed it, and the author's.
    tag = insert(:tag)
    external_post(tag, source: host, author_host: "relay.example")
    external_post(tag, source: "relay.example", author_host: host)
  end

  defp hosts_left do
    %{
      followers: uri_hosts(Follower, :actor_uri),
      remote_accounts: uri_hosts(RemoteAccount, :actor_uri),
      notes: uri_hosts(Note, :actor_uri),
      deliveries: uri_hosts(Delivery, :inbox_uri),
      post_deliveries: uri_hosts(PostDelivery, :inbox_uri),
      external_post_sources: find_hosts(:source, :author_host),
      external_post_authors: find_hosts(:author_host, :source)
    }
  end

  # The hosts `field` names on the finds whose `other` field is the relay.
  defp find_hosts(field, other) do
    ExternalPost
    |> where([p], field(p, ^other) == "relay.example")
    |> select([p], field(p, ^field))
    |> Repo.all()
    |> MapSet.new()
  end

  defp uri_hosts(schema, field) do
    schema
    |> Repo.all()
    |> MapSet.new(&URI.parse(Map.fetch!(&1, field)).host)
  end

  describe "normalize_host/1" do
    test "reduces every shape an admin (or an actor URI) offers to the hostname" do
      for value <- [
            "mastodon.example",
            "Mastodon.Example",
            "  mastodon.example  ",
            "https://mastodon.example",
            "https://mastodon.example/users/bob",
            "https://mastodon.example:8443/users/bob",
            "@bob@mastodon.example",
            "bob@mastodon.example",
            "mastodon.example."
          ] do
        assert BlockedInstance.normalize_host(value) == "mastodon.example",
               "expected #{inspect(value)} to normalize to mastodon.example"
      end
    end

    test "returns nil for nothing host-shaped" do
      assert BlockedInstance.normalize_host("") == nil
      assert BlockedInstance.normalize_host("   ") == nil
      assert BlockedInstance.normalize_host(nil) == nil
      assert BlockedInstance.normalize_host(42) == nil
    end
  end

  describe "block_instance/2" do
    test "stores the bare host and marks who blocked it" do
      operator = admin()

      assert {:ok, {blocked, _purged}} =
               Fediverse.block_instance(
                 %{"host" => "https://Spam.Example/users/bot", "reason" => "spam wave"},
                 operator
               )

      assert blocked.host == "spam.example"
      assert blocked.reason == "spam wave"
      assert blocked.blocked_by_id == operator.id
      assert Fediverse.blocked_instance_count() == 1
    end

    test "rejects anything that is not a server name" do
      operator = admin()

      for host <- ["", "not a host", "localhost", "-bad-.example", "spam..example"] do
        assert {:error, %Ecto.Changeset{}} =
                 Fediverse.block_instance(%{"host" => host}, operator),
               "expected #{inspect(host)} to be rejected"
      end
    end

    test "blocking the same server twice is an error, not a duplicate row" do
      operator = admin()

      assert {:ok, _} = Fediverse.block_instance(%{"host" => "spam.example"}, operator)

      assert {:error, %Ecto.Changeset{}} =
               Fediverse.block_instance(%{"host" => "spam.example"}, operator)

      assert Fediverse.blocked_instance_count() == 1
    end
  end

  describe "instance_blocked?/1" do
    test "matches the host of an actor id, a keyId and a bare host" do
      {:ok, _} = Fediverse.block_instance(%{"host" => "spam.example"}, admin())

      assert Fediverse.instance_blocked?("https://spam.example/users/bot")
      assert Fediverse.instance_blocked?("https://spam.example/users/bot#main-key")
      assert Fediverse.instance_blocked?("spam.example")
      # A different server, and a host that merely ends in the blocked one.
      refute Fediverse.instance_blocked?("https://social.example/users/alice")
      refute Fediverse.instance_blocked?("https://notspam.example/users/bot")
      refute Fediverse.instance_blocked?(nil)
    end

    # Issue #2174: the host a status or an actor names is written by whoever
    # sent it, so `www.` in front of a blocked name walked straight past the
    # block. The fold runs one way only — a block on the alias is not a block
    # on the apex, which may be somebody else's server.
    test "a block covers the host's www. alias, and a block on the alias stays on it" do
      {:ok, _} = Fediverse.block_instance(%{"host" => "spam.example"}, admin())
      {:ok, _} = Fediverse.block_instance(%{"host" => "www.alias.example"}, admin())

      for blocked <- [
            "www.spam.example",
            "https://WWW.spam.example/users/bot",
            "@bot@www.www.spam.example",
            "www.alias.example",
            "www.www.alias.example"
          ] do
        assert Fediverse.instance_blocked?(blocked), "expected #{blocked} to be blocked"
      end

      for open <- ["alias.example", "wwwspam.example", "www.notspam.example", "spam.example.org"] do
        refute Fediverse.instance_blocked?(open), "expected #{open} to stay open"
      end

      assert Fediverse.blocked_hosts([
               "www.spam.example",
               "bob@www.www.alias.example",
               "alias.example",
               "wwwspam.example"
             ]) == MapSet.new(["www.spam.example", "www.www.alias.example"])
    end
  end

  describe "blocking purges what is already stored" do
    # The read path has no blocklist clause (`ExternalPosts.showable_query/0`
    # says why), so a find the fold covers but the purge missed would stay on
    # every card after the block.
    test "takes a tag find whose author sits at the blocked host's www. alias" do
      tag = insert(:tag)
      alias_row = external_post(tag, source: "relay.example", author_host: "www.spam.example")
      lookalike = external_post(tag, source: "relay.example", author_host: "www.notspam.example")

      assert {:ok, {_blocked, %{external_posts: 1}}} =
               Fediverse.block_instance(%{"host" => "spam.example"}, admin())

      refute Repo.get(ExternalPost, alias_row.id)
      assert Repo.get(ExternalPost, lookalike.id)
    end

    # A block reaches the `www.` alias at every gate (issue #2174), so the purge
    # must reach it in every table too, and never a name that merely shares
    # letters with the blocked one. It runs one way, as the gate does.
    test "takes the www. alias's rows from every table, and no lookalike's" do
      member = federating_member()

      stored =
        ~w(spam.example www.spam.example www.www.spam.example other.spam.example
           www.other.spam.example wwwspam.example spam.example.evil alias.example
           www.alias.example www.www.alias.example)

      Enum.each(stored, &store_everywhere(member, &1))

      assert {:ok, {_blocked, purged}} =
               Fediverse.block_instance(%{"host" => "spam.example"}, admin())

      # Three spellings, one row each, and two finds per spelling.
      assert Map.delete(purged, :cached_posts) == %{
               followers: 3,
               remote_accounts: 3,
               notes: 3,
               deliveries: 3,
               post_deliveries: 3,
               external_posts: 6
             }

      assert {:ok, {_blocked, %{followers: 2}}} =
               Fediverse.block_instance(%{"host" => "www.alias.example"}, admin())

      left =
        MapSet.new(~w(other.spam.example www.other.spam.example wwwspam.example
                      spam.example.evil alias.example))

      for {table, hosts} <- hosts_left(), do: assert(hosts == left, "#{table}")
    end

    test "removes that server's followers and queued deliveries, and no other server's" do
      member = federating_member()

      {:ok, _} =
        Fediverse.add_follower(member, %{
          actor_uri: "https://spam.example/users/bot",
          inbox_uri: "https://spam.example/inbox"
        })

      {:ok, _} =
        Fediverse.add_follower(member, %{
          actor_uri: "https://social.example/users/alice",
          inbox_uri: "https://social.example/inbox"
        })

      Repo.insert!(%Delivery{
        user_id: member.id,
        inbox_uri: "https://spam.example/inbox",
        activity_json: "{}",
        attempts: 0,
        next_attempt_at: DateTime.utc_now(:second)
      })

      Repo.insert!(%Delivery{
        user_id: member.id,
        inbox_uri: "https://social.example/inbox",
        activity_json: "{}",
        attempts: 0,
        next_attempt_at: DateTime.utc_now(:second)
      })

      assert {:ok, {_blocked, purged}} =
               Fediverse.block_instance(%{"host" => "spam.example"}, admin())

      # `notes` joined the tally with issue #1069: a block is also a takedown of
      # the replies that server's members wrote under vutuv posts.
      # `post_deliveries` joined with issue #1102: the record of what that server
      # received would only ever address a revocation nobody will deliver.
      # `remote_accounts` joined with issue #1160: a block cuts both directions,
      # so the accounts our members follow over there go too (and their follow
      # rows cascade off them).
      # `cached_posts` joined with issue #1161: a block also takes the posts
      # cached from accounts on that server, which cascade off the accounts.
      assert purged == %{
               followers: 1,
               remote_accounts: 0,
               cached_posts: 0,
               # And what a followed tag had pulled from that server, or from
               # its members wherever else it read them (issue #2127).
               external_posts: 0,
               deliveries: 1,
               notes: 0,
               post_deliveries: 0
             }

      assert [%Follower{actor_uri: "https://social.example/users/alice"}] = Repo.all(Follower)
      assert [%Delivery{inbox_uri: "https://social.example/inbox"}] = Repo.all(Delivery)
    end

    test "unblocking does not resurrect anything" do
      member = federating_member()

      {:ok, _} =
        Fediverse.add_follower(member, %{
          actor_uri: "https://spam.example/users/bot",
          inbox_uri: "https://spam.example/inbox"
        })

      {:ok, {blocked, _}} = Fediverse.block_instance(%{"host" => "spam.example"}, admin())
      assert Repo.aggregate(Follower, :count) == 0

      assert {:ok, _} = Fediverse.unblock_instance(blocked.id)
      assert Fediverse.blocked_instance_count() == 0
      assert Repo.aggregate(Follower, :count) == 0
      refute Fediverse.instance_blocked?("https://spam.example/users/bot")
    end
  end

  describe "inbound caps" do
    test "a server over its hourly cap is throttled while other servers are unaffected" do
      # Tiny budgets so the test states the rule instead of writing 600 rows.
      original_caps = Application.fetch_env(:vutuv, :fediverse_inbound_caps)
      Application.put_env(:vutuv, :fediverse_inbound_caps, {2, 2})

      on_exit(fn ->
        case original_caps do
          {:ok, was} -> Application.put_env(:vutuv, :fediverse_inbound_caps, was)
          :error -> Application.delete_env(:vutuv, :fediverse_inbound_caps)
        end
      end)

      member = federating_member()

      for n <- 1..2 do
        assert {:ok, _} =
                 Fediverse.add_follower(member, %{
                   actor_uri: "https://flood.example/users/bot#{n}",
                   inbox_uri: "https://flood.example/inbox"
                 })
      end

      assert {:error, :inbound_capped} =
               Fediverse.add_follower(member, %{
                 actor_uri: "https://flood.example/users/bot3",
                 inbox_uri: "https://flood.example/inbox"
               })

      # A different server still gets through: the budget is per host.
      assert {:ok, _} =
               Fediverse.add_follower(member, %{
                 actor_uri: "https://social.example/users/alice",
                 inbox_uri: "https://social.example/inbox"
               })

      assert Repo.aggregate(Follower, :count) == 3
    end

    test "one remote account cannot spend the whole host budget" do
      # Room for 10 rows from the host, but only 1 from any single actor.
      original_caps = Application.fetch_env(:vutuv, :fediverse_inbound_caps)
      Application.put_env(:vutuv, :fediverse_inbound_caps, {10, 1})

      on_exit(fn ->
        case original_caps do
          {:ok, was} -> Application.put_env(:vutuv, :fediverse_inbound_caps, was)
          :error -> Application.delete_env(:vutuv, :fediverse_inbound_caps)
        end
      end)

      member = federating_member()
      other = federating_member()

      attrs = %{
        actor_uri: "https://social.example/users/alice",
        inbox_uri: "https://social.example/inbox"
      }

      assert {:ok, _} = Fediverse.add_follower(member, attrs)
      assert {:error, :inbound_capped} = Fediverse.add_follower(other, attrs)
    end
  end

  describe "inbound_hosts/1" do
    test "counts what each server stores here, biggest first" do
      member = federating_member()

      for n <- 1..2 do
        {:ok, _} =
          Fediverse.add_follower(member, %{
            actor_uri: "https://busy.example/users/u#{n}",
            inbox_uri: "https://busy.example/inbox"
          })
      end

      {:ok, _} =
        Fediverse.add_follower(member, %{
          actor_uri: "https://quiet.example/users/u1",
          inbox_uri: "https://quiet.example/inbox"
        })

      assert [
               %{host: "busy.example", followers: 2},
               %{host: "quiet.example", followers: 1}
             ] = Fediverse.inbound_hosts()
    end
  end

  describe "outbound deliveries to a blocked server" do
    test "are dropped instead of sent" do
      member = federating_member()
      {:ok, _actor} = Fediverse.ensure_actor(member)

      delivery =
        Repo.insert!(%Delivery{
          user_id: member.id,
          inbox_uri: "https://spam.example/inbox",
          activity_json: "{}",
          attempts: 0,
          next_attempt_at: DateTime.utc_now(:second)
        })

      # Blocked *after* the row was queued, so the purge did not catch it: the
      # deliverer must refuse it too. Insert the block directly to skip the purge.
      Repo.insert!(%BlockedInstance{host: "spam.example"})

      assert Fediverse.deliver_due() == 1
      refute Repo.get(Delivery, delivery.id)
    end
  end
end
