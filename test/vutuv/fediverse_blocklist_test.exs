defmodule Vutuv.FediverseBlocklistTest do
  @moduledoc """
  The operator's blocklist and the inbound caps (issue #1067): the safety floor
  under everything a remote server sends us.

  async: false — the inbound caps live in the shared `Vutuv.RateLimiter` ETS
  table, which the SQL sandbox does not roll back, so a parallel module hitting
  the same host bucket would make these counts drift.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.BlockedInstance
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.Follower

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp admin, do: insert(:activated_user, admin?: true)

  defp federating_member do
    insert(:activated_user, fediverse_followers?: true)
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
  end

  describe "blocking purges what is already stored" do
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

      assert purged == %{followers: 1, deliveries: 1}
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
      Application.put_env(:vutuv, :fediverse_inbound_caps, {2, 2})
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_inbound_caps) end)

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
      Application.put_env(:vutuv, :fediverse_inbound_caps, {10, 1})
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_inbound_caps) end)

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
