defmodule Vutuv.FediverseTest do
  # The follow-only federation context: actors + keys, remote followers,
  # activity enqueueing and the signed outbound deliveries. async: false — the
  # HTTP stub and the SSRF resolver live in the application env.
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
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
end
