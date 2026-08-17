defmodule Vutuv.FediverseFollowerPruneTest do
  @moduledoc """
  The slow re-check that drops remote followers whose account is gone (issue
  #1072): what prunes (404/410), what deliberately does not (a timeout, a 5xx,
  a rate limit), and the caps that keep a run a trickle rather than a sweep.

  async: false — the HTTP stub lives in the application env, like the rest of
  the Fediverse tests.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follower
  alias Vutuv.Fediverse.FollowerPrune

  # A plug stub that answers per remote host, so one run can meet a gone
  # account and a server having a bad day at the same time. `answers` maps a
  # host to an HTTP status or `:timeout`.
  defp stub_hosts(answers) do
    stub(fn conn ->
      case Map.fetch!(answers, conn.host) do
        :timeout -> Req.Test.transport_error(conn, :timeout)
        status -> Plug.Conn.send_resp(conn, status, "")
      end
    end)
  end

  defp stub(fun) do
    Application.put_env(:vutuv, :fediverse_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp federated_user do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    user
  end

  defp organization_follower(organization, host) do
    Fediverse.add_organization_follower(organization, %{
      actor_uri: "https://#{host}/users/alice",
      inbox_uri: "https://#{host}/inbox"
    })
  end

  defp tag_follower(tag, host) do
    Fediverse.add_tag_follower(tag, %{
      actor_uri: "https://#{host}/users/alice",
      inbox_uri: "https://#{host}/inbox"
    })
  end

  defp follower(user, host, attrs \\ []) do
    {:ok, follower} =
      Fediverse.add_follower(user, %{
        actor_uri: "https://#{host}/users/alice",
        inbox_uri: "https://#{host}/inbox"
      })

    case attrs[:last_checked_at] do
      nil -> follower
      stamp -> follower |> Ecto.Changeset.change(last_checked_at: stamp) |> Repo.update!()
    end
  end

  describe "prune_due_followers/1" do
    test "a 410 (Gone) drops the row and records the removal for the report" do
      user = federated_user()
      follower(user, "gone.example")

      stub_hosts(%{"gone.example" => 410})

      assert Fediverse.prune_due_followers() == 1
      assert Fediverse.follower_count(user) == 0

      assert [prune] = Repo.all(FollowerPrune)
      assert prune.user_id == user.id
      assert prune.host == "gone.example"
      assert prune.status == 410
    end

    test "a 404 drops the row too" do
      user = federated_user()
      follower(user, "missing.example")

      stub_hosts(%{"missing.example" => 404})

      assert Fediverse.prune_due_followers() == 1
      assert Fediverse.follower_count(user) == 0
      assert [%FollowerPrune{status: 404}] = Repo.all(FollowerPrune)
    end

    test "a timeout, a 500 and a 429 keep the row and only move its clock" do
      user = federated_user()

      for host <- ~w(slow.example broken.example busy.example), do: follower(user, host)

      stub_hosts(%{
        "slow.example" => :timeout,
        "broken.example" => 500,
        "busy.example" => 429
      })

      assert Fediverse.prune_due_followers() == 0
      assert Fediverse.follower_count(user) == 3
      assert Repo.all(FollowerPrune) == []

      # Each row was still stamped, so the next run moves on to other followers
      # instead of retrying the same unhappy servers straight away.
      assert Enum.all?(Repo.all(Follower), &(&1.last_checked_at != nil))
    end

    # A remote account follows a member, a page (#1334) or a topic (#1330). The
    # ledger row held only `user_id`, NOT NULL, and the pruner wrote
    # `follower.user_id` into it whatever the follower was — so the day a page's
    # or a topic's remote account was deleted, the insert raised on a NOT NULL
    # violation instead of recording the removal. The fetch had no signer for
    # those two either, so it went out unsigned and an authorized-fetch server
    # answered 401, which reads as "still there" and kept the dead row forever.
    test "a page's gone follower is pruned and recorded against the page" do
      organization = insert(:organization)
      {:ok, _actor} = Fediverse.ensure_organization_actor(organization)
      {:ok, _follower} = organization_follower(organization, "gone.example")

      stub_hosts(%{"gone.example" => 410})

      assert Fediverse.prune_due_followers() == 1
      assert Fediverse.organization_remote_follower_count(organization) == 0

      assert [prune] = Repo.all(FollowerPrune)
      assert prune.organization_id == organization.id
      assert prune.user_id == nil
      assert prune.tag_id == nil
      assert prune.host == "gone.example"
    end

    test "a topic's gone follower is pruned and recorded against the tag" do
      tag = insert(:tag)
      {:ok, _actor} = Fediverse.ensure_tag_actor(tag)
      {:ok, _follower} = tag_follower(tag, "gone.example")

      stub_hosts(%{"gone.example" => 410})

      assert Fediverse.prune_due_followers() == 1

      assert [prune] = Repo.all(FollowerPrune)
      assert prune.tag_id == tag.id
      assert prune.user_id == nil
      assert prune.organization_id == nil
    end

    test "a page's and a topic's actor fetch are signed with their own keys" do
      organization = insert(:organization)
      tag = insert(:tag)
      {:ok, _} = Fediverse.ensure_organization_actor(organization)
      {:ok, _} = Fediverse.ensure_tag_actor(tag)
      {:ok, _} = organization_follower(organization, "page.example")
      {:ok, _} = tag_follower(tag, "topic.example")
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:signature, conn.host, Plug.Conn.get_req_header(conn, "signature")})
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      Fediverse.prune_due_followers()

      assert_received {:signature, "page.example", [page_signature]}
      assert_received {:signature, "topic.example", [topic_signature]}
      assert page_signature =~ ~s(keyId=")
      assert topic_signature =~ ~s(keyId=")
    end

    test "the actor fetch is signed with the member's own key" do
      user = federated_user()
      follower(user, "authorized.example")
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:signature, Plug.Conn.get_req_header(conn, "signature")})
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      Fediverse.prune_due_followers()

      assert_received {:signature, [signature]}
      assert signature =~ ~s(keyId=")
    end

    test "a row checked recently is skipped entirely" do
      user = federated_user()
      recent = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600)
      follower(user, "gone.example", last_checked_at: recent)

      stub_hosts(%{"gone.example" => 410})

      assert Fediverse.followers_due_for_prune() == []
      assert Fediverse.prune_due_followers() == 0
      assert Fediverse.follower_count(user) == 1
    end

    test "a row last checked longer ago than the interval is due again" do
      user = federated_user()
      days = Fediverse.prune_recheck_days()
      stale = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -(days + 1) * 86_400)
      follower(user, "gone.example", last_checked_at: stale)

      stub_hosts(%{"gone.example" => 410})

      assert Fediverse.prune_due_followers() == 1
      assert Fediverse.follower_count(user) == 0
    end

    test "the installation-wide switch stops it, without a single request" do
      user = federated_user()
      follower(user, "gone.example")

      stub(fn _conn -> raise "the disabled installation must not call out" end)
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      assert Fediverse.prune_due_followers() == 0
      assert Fediverse.follower_count(user) == 1
    end
  end

  describe "followers_due_for_prune/1" do
    test "the batch cap holds however many rows are due" do
      user = federated_user()
      over = Fediverse.prune_batch() + 5

      # One host each, so only the batch cap can bite here.
      for i <- 1..over, do: follower(user, "h#{i}.example")

      assert length(Fediverse.followers_due_for_prune()) == Fediverse.prune_batch()
    end

    test "one server never fills the run by itself" do
      user = federated_user()

      for i <- 1..15 do
        {:ok, _} =
          Fediverse.add_follower(user, %{
            actor_uri: "https://big.example/users/u#{i}",
            inbox_uri: "https://big.example/inbox"
          })
      end

      due = Fediverse.followers_due_for_prune()

      assert length(due) < 15
      assert Enum.all?(due, &(&1.actor_uri =~ "big.example"))
    end

    test "the oldest check comes first, never-checked rows before all of them" do
      user = federated_user()
      now = NaiveDateTime.utc_now(:second)

      follower(user, "recent.example", last_checked_at: NaiveDateTime.add(now, -40 * 86_400))
      follower(user, "ancient.example", last_checked_at: NaiveDateTime.add(now, -400 * 86_400))
      follower(user, "never.example")

      assert ["never.example", "ancient.example", "recent.example"] ==
               Enum.map(Fediverse.followers_due_for_prune(), &URI.parse(&1.actor_uri).host)
    end
  end
end
