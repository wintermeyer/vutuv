defmodule Vutuv.FediverseTest do
  # The follow-only federation context: actors + keys, remote followers,
  # activity enqueueing and the signed outbound deliveries. async: false — the
  # HTTP stub and the SSRF resolver live in the application env.
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.Follower
  alias VutuvWeb.Fediverse.Docs

  defp stub_remote(fun) do
    Application.put_env(:vutuv, :fediverse_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp federated_user(attrs \\ []) do
    insert(:activated_user, Keyword.merge([fediverse_followers?: true], attrs))
  end

  describe "federated?/1" do
    test "requires the opt-in, a confirmed account and good standing" do
      assert Fediverse.federated?(federated_user())
      refute Fediverse.federated?(insert(:activated_user))
      refute Fediverse.federated?(insert(:user, fediverse_followers?: true))
      refute Fediverse.federated?(federated_user(frozen_at: ~N[2026-07-01 00:00:00]))
      refute Fediverse.federated?(federated_user(deactivated_at: ~N[2026-07-01 00:00:00]))
      refute Fediverse.federated?(federated_user(suspended_until: ~N[2099-01-01 00:00:00]))
    end

    test "the global switch turns everything off" do
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      refute Fediverse.federated?(federated_user())
    end
  end

  describe "ensure_actor/1" do
    test "creates the keypair once and returns the same actor after" do
      user = federated_user()

      {:ok, actor} = Fediverse.ensure_actor(user)
      {:ok, again} = Fediverse.ensure_actor(user)

      assert actor.id == again.id
      assert actor.private_key_pem =~ "BEGIN RSA PRIVATE KEY"
      assert actor.public_key_pem =~ "BEGIN PUBLIC KEY"
    end
  end

  describe "followers" do
    test "add is idempotent per remote actor and remove deletes" do
      user = federated_user()

      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: "https://social.example/users/alice",
          inbox_uri: "https://social.example/users/alice/inbox",
          shared_inbox_uri: "https://social.example/inbox"
        })

      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: "https://social.example/users/alice",
          inbox_uri: "https://social.example/users/alice/inbox"
        })

      assert Fediverse.follower_count(user) == 1

      Fediverse.remove_follower(user, "https://social.example/users/alice")
      assert Fediverse.follower_count(user) == 0
    end

    test "delivery_inboxes prefers the shared inbox and dedupes by it" do
      user = federated_user()

      for name <- ~w(alice bob) do
        {:ok, _} =
          Fediverse.add_follower(user, %{
            actor_uri: "https://social.example/users/#{name}",
            inbox_uri: "https://social.example/users/#{name}/inbox",
            shared_inbox_uri: "https://social.example/inbox"
          })
      end

      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: "https://other.example/users/carol",
          inbox_uri: "https://other.example/users/carol/inbox"
        })

      assert Enum.sort(Fediverse.delivery_inboxes(user)) == [
               "https://other.example/users/carol/inbox",
               "https://social.example/inbox"
             ]
    end

    test "a repeat Follow re-syncs the cached handle and display name" do
      user = federated_user()

      for handle <- ~w(alice alice_renamed) do
        {:ok, _} =
          Fediverse.add_follower(user, %{
            actor_uri: "https://social.example/users/alice",
            inbox_uri: "https://social.example/users/alice/inbox",
            handle: handle,
            name: "Alice #{handle}"
          })
      end

      # Read back from the database: the insert's own return value carries the
      # attrs we sent whether or not the upsert stored them.
      assert [follower] = Fediverse.list_followers(user)
      assert follower.handle == "alice_renamed"
      assert follower.name == "Alice alice_renamed"
    end

    test "refresh_follower/2 re-syncs an existing row and never creates one" do
      user = federated_user()
      alice = "https://social.example/users/alice"

      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: alice,
          inbox_uri: "https://social.example/users/alice/inbox",
          handle: "alice",
          name: "Alice Example"
        })

      :ok =
        Fediverse.refresh_follower(user, %{
          actor_uri: alice,
          inbox_uri: "https://social.example/users/alice/inbox2",
          shared_inbox_uri: "https://social.example/inbox",
          handle: "alice_renamed",
          name: "Alice Renamed"
        })

      assert [follower] = Fediverse.list_followers(user)
      assert follower.handle == "alice_renamed"
      assert follower.name == "Alice Renamed"
      assert follower.inbox_uri == "https://social.example/users/alice/inbox2"
      assert follower.shared_inbox_uri == "https://social.example/inbox"

      # An Update is a broadcast, not a follow request: a stranger's must not
      # turn into a follower row.
      :ok =
        Fediverse.refresh_follower(user, %{
          actor_uri: "https://social.example/users/mallory",
          inbox_uri: "https://social.example/users/mallory/inbox"
        })

      assert Fediverse.follower_count(user) == 1
    end
  end

  describe "federate_new_post/1" do
    test "queues one signed delivery per distinct inbox" do
      user = federated_user()
      {:ok, _actor} = Fediverse.ensure_actor(user)

      for host <- ~w(one.example two.example) do
        {:ok, _} =
          Fediverse.add_follower(user, %{
            actor_uri: "https://#{host}/users/x",
            inbox_uri: "https://#{host}/inbox"
          })
      end

      post = insert(:post, user: user, body: "Hallo Fediverse")

      assert :ok == Fediverse.federate_new_post(post)

      deliveries = Repo.all(Delivery)
      assert length(deliveries) == 2
      assert Enum.all?(deliveries, &(&1.activity_json =~ ~s("type":"Create")))
    end

    test "does nothing for restricted posts, non-opted authors or no followers" do
      opted = federated_user()
      {:ok, _} = Fediverse.ensure_actor(opted)

      # No followers -> nothing to deliver.
      assert :skip == Fediverse.federate_new_post(insert(:post, user: opted))

      # Author without the opt-in.
      plain = insert(:activated_user)
      assert :skip == Fediverse.federate_new_post(insert(:post, user: plain))

      # Restricted post of an opted-in author with followers.
      {:ok, _} =
        Fediverse.add_follower(opted, %{
          actor_uri: "https://social.example/users/alice",
          inbox_uri: "https://social.example/inbox-a"
        })

      restricted =
        create_post!(opted, %{body: "members only", denials: [%{"wildcard" => "logged_out"}]})

      assert :skip == Fediverse.federate_new_post(restricted)
      assert Repo.aggregate(Delivery, :count) == 0
    end

    test "does nothing once the member has moved out" do
      user = federated_user(moved_to: "https://mastodon.example/users/newme")
      {:ok, _} = Fediverse.ensure_actor(user)

      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: "https://social.example/users/a",
          inbox_uri: "https://social.example/inbox"
        })

      assert :skip == Fediverse.federate_new_post(insert(:post, user: user))
      assert Repo.aggregate(Delivery, :count) == 0
    end
  end

  describe "move_out/2 (issue #986, half 2)" do
    @target "https://mastodon.example/users/newme"

    # A target actor whose alsoKnownAs is whatever the test needs, or whose id
    # can be forced (for the self-move check).
    defp stub_target(also_known_as, id \\ @target) do
      stub_remote(fn conn ->
        doc =
          Jason.encode!(%{
            "id" => id,
            "type" => "Person",
            "inbox" => id <> "/inbox",
            "alsoKnownAs" => also_known_as
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, doc)
      end)
    end

    defp with_follower(user) do
      {:ok, _} = Fediverse.ensure_actor(user)

      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: "https://social.example/users/a",
          inbox_uri: "https://social.example/inbox"
        })

      user
    end

    test "broadcasts a Move and stamps moved_to when the target lists us as an alias" do
      user = with_follower(federated_user())
      stub_target([Docs.actor_url(user)])

      assert {:ok, moved} = Fediverse.move_out(user, @target)
      assert moved.moved_to == @target
      assert moved.moved_at

      delivery = Repo.one(Delivery)
      assert delivery.activity_json =~ ~s("type":"Move")
      assert delivery.activity_json =~ @target
    end

    test "rejects a target that does not list us as an alias, storing nothing" do
      user = with_follower(federated_user())
      stub_target(["https://someone.else/actor"])

      assert {:error, :alias_missing} = Fediverse.move_out(user, @target)
      assert Repo.aggregate(Delivery, :count) == 0
      assert Repo.reload(user).moved_to == nil
    end

    test "refuses to move to this same account" do
      user = with_follower(federated_user())
      # The fetched target's id IS our own actor URL.
      stub_target([Docs.actor_url(user)], Docs.actor_url(user))

      assert {:error, :self_target} = Fediverse.move_out(user, @target)
    end

    test "rejects a non-https target without reaching the network" do
      user = with_follower(federated_user())
      assert {:error, :invalid_target} = Fediverse.move_out(user, "not-a-url")
    end

    test "requires federation" do
      assert {:error, :not_federated} = Fediverse.move_out(insert(:activated_user), @target)
    end

    test "holds within the cooldown window, then allows a move after it" do
      recent =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-5 * 86_400, :second)
        |> NaiveDateTime.truncate(:second)

      user = with_follower(federated_user(moved_at: recent))
      stub_target([Docs.actor_url(user)])

      assert {:error, :cooldown} = Fediverse.move_out(user, @target)

      long_ago = NaiveDateTime.add(recent, -40 * 86_400, :second)
      {:ok, aged} = user |> Ecto.Changeset.change(moved_at: long_ago) |> Repo.update()
      assert {:ok, _} = Fediverse.move_out(aged, @target)
    end
  end

  describe "cancel_move/1 and moved?/1" do
    test "moved?/1 reflects the redirect" do
      refute Fediverse.moved?(federated_user())
      assert Fediverse.moved?(federated_user(moved_to: @target))
    end

    test "cancel clears moved_to but keeps moved_at (the cooldown must hold)" do
      at = ~N[2026-07-20 10:00:00]
      user = federated_user(moved_to: @target, moved_at: at)

      {:ok, cancelled} = Fediverse.cancel_move(user)

      assert cancelled.moved_to == nil
      assert cancelled.moved_at == at
    end
  end

  describe "deliver_due/0" do
    test "signs and POSTs the activity, then drops the row" do
      parent = self()

      stub_remote(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:delivered, conn.request_path, Map.new(conn.req_headers), body})
        Plug.Conn.send_resp(conn, 202, "")
      end)

      user = federated_user()
      {:ok, _} = Fediverse.ensure_actor(user)

      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: "https://social.example/users/alice",
          inbox_uri: "https://social.example/users/alice/inbox"
        })

      post = insert(:post, user: user)
      :ok = Fediverse.federate_new_post(post)

      assert Fediverse.deliver_due() == 1

      assert_receive {:delivered, "/users/alice/inbox", headers, body}
      assert headers["content-type"] =~ "application/activity+json"
      assert headers["signature"] =~ ~s(keyId="#{Docs.key_id(user)}")
      assert headers["digest"] =~ "SHA-256="
      assert body =~ ~s("type":"Create")

      assert Repo.aggregate(Delivery, :count) == 0
    end

    test "a failing inbox backs off and eventually gives up" do
      stub_remote(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      user = federated_user()
      {:ok, _} = Fediverse.ensure_actor(user)

      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: "https://social.example/users/alice",
          inbox_uri: "https://social.example/users/alice/inbox"
        })

      :ok = Fediverse.federate_new_post(insert(:post, user: user))

      assert Fediverse.deliver_due() == 1

      delivery = Repo.one(Delivery)
      assert delivery.attempts == 1
      assert delivery.last_error =~ "500"
      assert DateTime.compare(delivery.next_attempt_at, DateTime.utc_now()) == :gt

      # The final allowed attempt drops the row instead of rescheduling.
      delivery
      |> Ecto.Changeset.change(
        attempts: 7,
        next_attempt_at: DateTime.utc_now(:second) |> DateTime.add(-1)
      )
      |> Repo.update!()

      assert Fediverse.deliver_due() == 1
      assert Repo.aggregate(Delivery, :count) == 0
    end
  end

  describe "fetch_remote_actor/1" do
    test "fetches and parses id, inbox, sharedInbox and the public key" do
      stub_remote(fn conn ->
        body =
          Jason.encode!(%{
            "id" => "https://social.example/users/alice",
            "type" => "Person",
            "preferredUsername" => "alice",
            "name" => "Alice Example",
            "inbox" => "https://social.example/users/alice/inbox",
            "endpoints" => %{"sharedInbox" => "https://social.example/inbox"},
            "publicKey" => %{
              "id" => "https://social.example/users/alice#main-key",
              "publicKeyPem" => "-----BEGIN PUBLIC KEY-----..."
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:ok, remote} =
               Fediverse.fetch_remote_actor("https://social.example/users/alice#main-key")

      assert remote.id == "https://social.example/users/alice"
      assert remote.inbox == "https://social.example/users/alice/inbox"
      assert remote.shared_inbox == "https://social.example/inbox"
      assert remote.preferred_username == "alice"
      assert remote.name == "Alice Example"
      assert remote.public_key_pem =~ "BEGIN PUBLIC KEY"
    end

    test "refuses plain-http and internal hosts" do
      assert {:error, _} = Fediverse.fetch_remote_actor("http://social.example/users/alice")

      original = Application.fetch_env!(:vutuv, :ssrf_resolver)
      on_exit(fn -> Application.put_env(:vutuv, :ssrf_resolver, original) end)

      Application.put_env(:vutuv, :ssrf_resolver, fn _host, _family -> {:ok, [{127, 0, 0, 1}]} end)

      assert {:error, _} = Fediverse.fetch_remote_actor("https://internal.example/users/x")
    end
  end

  describe "the remote-follower list (settings page)" do
    test "add_follower captures the remote handle and display name" do
      user = federated_user()

      {:ok, follower} =
        Fediverse.add_follower(user, %{
          actor_uri: "https://social.example/users/alice",
          inbox_uri: "https://social.example/users/alice/inbox",
          handle: "alice",
          name: "Alice Example"
        })

      assert follower.handle == "alice"
      assert follower.name == "Alice Example"
    end

    test "list_followers/1 returns a member's followers newest-first" do
      user = federated_user()

      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: "https://social.example/users/alice",
          inbox_uri: "https://social.example/users/alice/inbox",
          handle: "alice",
          name: "Alice Example"
        })

      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: "https://other.example/users/bob",
          inbox_uri: "https://other.example/users/bob/inbox",
          handle: "bob"
        })

      # Another member's follower must not leak into this member's list.
      {:ok, _} =
        Fediverse.add_follower(federated_user(), %{
          actor_uri: "https://social.example/users/mallory",
          inbox_uri: "https://social.example/users/mallory/inbox"
        })

      assert [newest, oldest] = Fediverse.list_followers(user)
      assert newest.handle == "bob"
      assert oldest.handle == "alice"
    end

    test "display_handle/1 renders @user@host, falling back to the actor URI" do
      captured =
        %Follower{handle: "alice", actor_uri: "https://social.example/users/alice"}

      derived = %Follower{handle: nil, actor_uri: "https://mastodon.example/@carol"}

      assert Follower.display_handle(captured) == "@alice@social.example"
      assert Follower.display_handle(derived) == "@carol@mastodon.example"
    end
  end

  describe "operational stats" do
    test "stats/0 reports federating members, remote followers, queue depth and stuck rows" do
      u1 = federated_user()
      u2 = federated_user()
      # Opted in but not in good standing, and a plain member: neither counts.
      _frozen = federated_user(frozen_at: ~N[2026-07-01 00:00:00])
      _plain = insert(:activated_user)

      for {u, host} <- [{u1, "a.example"}, {u2, "b.example"}] do
        {:ok, _} =
          Fediverse.add_follower(u, %{
            actor_uri: "https://#{host}/users/x",
            inbox_uri: "https://#{host}/inbox"
          })
      end

      Repo.insert!(%Delivery{
        user_id: u1.id,
        inbox_uri: "https://a.example/inbox",
        activity_json: "{}",
        attempts: 0,
        next_attempt_at: DateTime.utc_now(:second)
      })

      Repo.insert!(%Delivery{
        user_id: u2.id,
        inbox_uri: "https://b.example/inbox",
        activity_json: "{}",
        attempts: 3,
        next_attempt_at: DateTime.utc_now(:second),
        last_error: "HTTP 500"
      })

      assert Fediverse.stats() == %{
               federating_members: 2,
               remote_followers: 2,
               queue_depth: 2,
               stuck_deliveries: 1,
               blocked_instances: 0
             }
    end
  end
end
