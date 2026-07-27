defmodule Vutuv.FediverseRemoteFollowsTest do
  @moduledoc """
  A member here following an account on another network (issue #1160): the
  resolution, the gates, the Follow/Accept/Reject/Undo handshake and the
  browser queries.

  `async: false` — the HTTP stub and the SSRF resolver live in the application
  env, which the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias VutuvWeb.Fediverse.Docs

  @actor_uri "https://social.example/users/them"

  defp stub_remote(fun) do
    Application.put_env(:vutuv, :fediverse_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  # WebFinger answers the `self` link, the actor URL answers the document.
  # Everything a follow needs, from the two requests it really makes.
  defp stub_account(overrides \\ %{}) do
    stub_remote(fn conn ->
      {type, body} =
        case conn.request_path do
          "/.well-known/webfinger" ->
            {"application/jrd+json",
             %{
               "links" => [
                 %{"rel" => "http://webfinger.net/rel/profile-page", "href" => "https://x/@them"},
                 %{
                   "rel" => "self",
                   "type" => "application/activity+json",
                   "href" => @actor_uri
                 }
               ]
             }}

          _actor ->
            {"application/activity+json",
             Map.merge(
               %{
                 "id" => @actor_uri,
                 "type" => "Person",
                 "preferredUsername" => "them",
                 "name" => "Them",
                 "summary" => "<p>Writes about <b>trains</b>.</p>",
                 "inbox" => "https://social.example/users/them/inbox",
                 "endpoints" => %{"sharedInbox" => "https://social.example/inbox"},
                 "publicKey" => %{
                   "id" => @actor_uri <> "#main-key",
                   "publicKeyPem" => "PEM"
                 }
               },
               overrides
             )}
        end

      conn
      |> Plug.Conn.put_resp_content_type(type)
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)
  end

  # The endpoint's host, for the one gate that compares an address against this
  # installation's own name. Phoenix caches the endpoint config, so the app env
  # alone is not enough — `config_change/2` is what re-reads it.
  defp with_endpoint_host(host) do
    original = Application.get_env(:vutuv, VutuvWeb.Endpoint)
    changed = Keyword.put(original, :url, Keyword.put(original[:url] || [], :host, host))

    Application.put_env(:vutuv, VutuvWeb.Endpoint, changed)
    VutuvWeb.Endpoint.config_change([{VutuvWeb.Endpoint, changed}], [])

    on_exit(fn ->
      Application.put_env(:vutuv, VutuvWeb.Endpoint, original)
      VutuvWeb.Endpoint.config_change([{VutuvWeb.Endpoint, original}], [])
    end)
  end

  defp federated_user(attrs \\ []) do
    user = insert(:activated_user, Keyword.merge([fediverse_followers?: true], attrs))
    {:ok, _actor} = Fediverse.ensure_actor(user)
    user
  end

  defp deliveries(user) do
    Repo.all(from(d in Delivery, where: d.user_id == ^user.id))
    |> Enum.map(&Jason.decode!(&1.activity_json))
  end

  describe "follow_remote/2" do
    test "resolves the address, stores the account and queues a signed Follow" do
      stub_account()
      user = federated_user()

      assert {:ok, follow} = Fediverse.follow_remote(user, "@them@social.example")

      # The row starts as a request, because that is what a Follow is.
      assert follow.state == "requested"
      assert follow.user_id == user.id
      assert follow.follow_activity_id == Docs.actor_url(user) <> "#follows/" <> follow.id

      account = Repo.get!(RemoteAccount, follow.remote_account_id)
      assert account.actor_uri == @actor_uri
      assert account.host == "social.example"
      assert account.handle == "them"
      assert account.name == "Them"
      assert account.inbox_uri == "https://social.example/users/them/inbox"
      assert account.shared_inbox_uri == "https://social.example/inbox"
      assert account.public_key_pem == "PEM"
      # The self-description is a stranger's HTML, so it is stored as text.
      assert account.summary == "Writes about trains."
      refute account.summary =~ "<b>"

      assert [%{"type" => "Follow"} = activity] = deliveries(user)
      assert activity["id"] == follow.follow_activity_id
      assert activity["actor"] == Docs.actor_url(user)
      assert activity["object"] == @actor_uri
      # Addressed to the target alone: a follow request is a message to one
      # account, never an announcement.
      assert activity["to"] == [@actor_uri]
      refute activity["cc"]

      assert [delivery] = Repo.all(Delivery)
      assert delivery.inbox_uri == "https://social.example/users/them/inbox"
    end

    test "a second follow of the same account is refused, and mints no second account row" do
      stub_account()
      user = federated_user()

      assert {:ok, _follow} = Fediverse.follow_remote(user, "@them@social.example")
      assert {:error, :already_following} = Fediverse.follow_remote(user, "@them@social.example")

      assert Repo.aggregate(RemoteAccount, :count) == 1
      assert Repo.aggregate(Follow, :count) == 1
    end

    test "two members following the same account share one account row" do
      stub_account()
      one = federated_user()
      two = federated_user()

      assert {:ok, first} = Fediverse.follow_remote(one, "@them@social.example")
      assert {:ok, second} = Fediverse.follow_remote(two, "@them@social.example")

      assert first.remote_account_id == second.remote_account_id
      assert Repo.aggregate(RemoteAccount, :count) == 1
    end

    test "a member who does not federate is told so, and nothing leaves" do
      stub_account()

      assert {:error, :not_federating} =
               Fediverse.follow_remote(insert(:activated_user), "@them@social.example")

      assert Repo.aggregate(Delivery, :count) == 0
      assert Repo.aggregate(RemoteAccount, :count) == 0
    end

    test "a member who moved their account away no longer follows from here" do
      stub_account()
      user = federated_user(moved_to: "https://elsewhere.example/users/them")

      assert {:error, :moved} = Fediverse.follow_remote(user, "@them@social.example")
    end

    test "the installation switch refuses before anything is resolved" do
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      assert {:error, :fediverse_disabled} =
               Fediverse.follow_remote(insert(:activated_user), "@them@social.example")
    end

    test "a blocked server is refused without an outbound request" do
      stub_remote(fn _conn -> raise "a blocked server must never be contacted" end)
      admin = insert(:user, admin?: true)
      {:ok, _} = Fediverse.block_instance(%{"host" => "social.example"}, admin)

      assert {:error, :instance_blocked} =
               Fediverse.follow_remote(federated_user(), "@them@social.example")
    end

    test "an address on this very installation is named as a vutuv account" do
      stub_remote(fn _conn -> raise "our own members need no WebFinger lookup" end)
      # The test endpoint answers as "localhost", which is not a Fediverse
      # address at all, so the installation has to wear a real hostname for this
      # gate to be the one that fires.
      with_endpoint_host("vutuv.test")
      other = insert(:activated_user)

      assert {:error, :local_account} =
               Fediverse.follow_remote(federated_user(), "@#{other.username}@vutuv.test")
    end

    test "a typo is refused before the network is touched" do
      stub_remote(fn _conn -> raise "an invalid address must never be resolved" end)

      assert {:error, :invalid_address} = Fediverse.follow_remote(federated_user(), "them")
    end

    test "a WebFinger document with no ActivityPub identity is not followable" do
      stub_remote(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "links" => [
              %{"rel" => "http://webfinger.net/rel/profile-page", "href" => "https://x/@them"}
            ]
          })
        )
      end)

      assert {:error, :no_actor} =
               Fediverse.follow_remote(federated_user(), "@them@social.example")
    end

    test "the hourly budget stops a run of requests" do
      stub_account()
      Application.put_env(:vutuv, :fediverse_remote_follow_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_remote_follow_limit) end)

      user = federated_user()

      assert {:ok, _follow} = Fediverse.follow_remote(user, "@them@social.example")

      assert {:error, :follow_capped} =
               Fediverse.follow_remote(user, "@other@social.example")
    end

    test "the total ceiling refuses one more follow" do
      stub_account()
      Application.put_env(:vutuv, :fediverse_max_remote_follows, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_max_remote_follows) end)

      user = federated_user()

      assert {:ok, _follow} = Fediverse.follow_remote(user, "@them@social.example")
      assert {:error, :follow_limit} = Fediverse.follow_remote(user, "@other@social.example")
    end
  end

  describe "Accept and Reject" do
    setup do
      stub_account()
      user = federated_user()
      {:ok, follow} = Fediverse.follow_remote(user, "@them@social.example")
      %{user: user, follow: follow}
    end

    test "an Accept naming our Follow seals it", %{user: user, follow: follow} do
      activity = %{
        "type" => "Accept",
        "actor" => @actor_uri,
        "object" => %{
          "id" => follow.follow_activity_id,
          "type" => "Follow",
          "actor" => Docs.actor_url(user),
          "object" => @actor_uri
        }
      }

      assert :ok = Fediverse.accept_remote_follow(user, activity, @actor_uri)
      assert Repo.get!(Follow, follow.id).state == "accepted"
      assert Fediverse.accepted_follow_count(user) == 1
    end

    test "a bare object id is accepted too", %{user: user, follow: follow} do
      activity = %{"type" => "Accept", "object" => follow.follow_activity_id}

      assert :ok = Fediverse.accept_remote_follow(user, activity, @actor_uri)
      assert Repo.get!(Follow, follow.id).state == "accepted"
    end

    test "another server cannot seal a follow it was not sent", %{user: user, follow: follow} do
      activity = %{"type" => "Accept", "object" => follow.follow_activity_id}

      assert :ok =
               Fediverse.accept_remote_follow(user, activity, "https://elsewhere.example/users/x")

      assert Repo.get!(Follow, follow.id).state == "requested"
    end

    test "a Reject removes the row", %{user: user, follow: follow} do
      activity = %{"type" => "Reject", "object" => follow.follow_activity_id}

      assert :ok = Fediverse.reject_remote_follow(user, activity, @actor_uri)
      refute Repo.get(Follow, follow.id)
      # The account itself stays: somebody else may follow it, and the next
      # attempt should not need a fresh resolve.
      assert Repo.aggregate(RemoteAccount, :count) == 1
    end

    test "a request nobody answered is not published", %{user: user} do
      assert Fediverse.remote_follow_count(user) == 1
      assert Fediverse.accepted_follow_count(user) == 0
    end
  end

  describe "unfollow_remote/2" do
    test "queues an Undo(Follow) with the original id and deletes the row" do
      stub_account()
      user = federated_user()
      {:ok, follow} = Fediverse.follow_remote(user, "@them@social.example")

      assert :ok = Fediverse.unfollow_remote(user, follow.id)
      refute Repo.get(Follow, follow.id)

      assert [_follow_activity, %{"type" => "Undo"} = undo] = deliveries(user)
      assert undo["object"]["id"] == follow.follow_activity_id
      assert undo["object"]["type"] == "Follow"
      assert undo["to"] == [@actor_uri]
    end

    test "another member's follow id resolves to nothing" do
      stub_account()
      owner = federated_user()
      stranger = federated_user()
      {:ok, follow} = Fediverse.follow_remote(owner, "@them@social.example")

      assert {:error, :not_found} = Fediverse.unfollow_remote(stranger, follow.id)
      assert Repo.get(Follow, follow.id)
    end
  end

  describe "drop_remote_follows/1" do
    test "leaving the Fediverse withdraws every follow" do
      stub_account()
      user = federated_user()
      {:ok, _follow} = Fediverse.follow_remote(user, "@them@social.example")

      # The switch is off by the time this runs, which is exactly why the Undo
      # is gated on ever_federated?/1 and not on federated?/1.
      {:ok, user} = Vutuv.Accounts.update_user(user, %{"fediverse_followers?" => "false"})

      assert Fediverse.drop_remote_follows(user) == 1
      assert Repo.aggregate(Follow, :count) == 0
      assert Enum.any?(deliveries(user), &(&1["type"] == "Undo"))
    end
  end

  describe "the remote account row" do
    test "an actor Update re-syncs it for everybody who follows it" do
      stub_account()
      user = federated_user()
      {:ok, follow} = Fediverse.follow_remote(user, "@them@social.example")

      assert :ok =
               Fediverse.refresh_remote_account(%{
                 id: @actor_uri,
                 inbox: "https://social.example/users/them/inbox",
                 shared_inbox: nil,
                 preferred_username: "renamed",
                 name: "Renamed",
                 summary: "<p>New bio.</p>",
                 public_key_id: nil,
                 public_key_pem: "PEM",
                 also_known_as: []
               })

      account = Repo.get!(RemoteAccount, follow.remote_account_id)
      assert account.handle == "renamed"
      assert account.summary == "New bio."
      # One row, still: an Update is a re-sync, never a second account.
      assert Repo.aggregate(RemoteAccount, :count) == 1
    end

    test "an Update for an account nobody follows mints nothing" do
      assert :ok =
               Fediverse.refresh_remote_account(%{
                 id: "https://social.example/users/stranger",
                 inbox: "https://social.example/inbox",
                 shared_inbox: nil,
                 preferred_username: "stranger",
                 name: nil,
                 summary: nil,
                 public_key_id: nil,
                 public_key_pem: nil,
                 also_known_as: []
               })

      assert Repo.aggregate(RemoteAccount, :count) == 0
    end

    test "a deleted account takes every follow of it with it" do
      stub_account()
      user = federated_user()
      {:ok, _follow} = Fediverse.follow_remote(user, "@them@social.example")

      assert :ok = Fediverse.remove_remote_account(@actor_uri)
      assert Repo.aggregate(RemoteAccount, :count) == 0
      assert Repo.aggregate(Follow, :count) == 0
    end

    test "blocking a server purges the accounts our members follow there" do
      stub_account()
      user = federated_user()
      {:ok, _follow} = Fediverse.follow_remote(user, "@them@social.example")

      admin = insert(:user, admin?: true)
      {:ok, {_blocked, purged}} = Fediverse.block_instance(%{"host" => "social.example"}, admin)

      assert purged.remote_accounts == 1
      assert Repo.aggregate(RemoteAccount, :count) == 0
      assert Repo.aggregate(Follow, :count) == 0
    end

    test "the members who follow an account are the addressees of its broadcasts" do
      stub_account()
      user = federated_user()
      {:ok, _follow} = Fediverse.follow_remote(user, "@them@social.example")

      assert [%{id: found}] = Fediverse.remote_follow_users(@actor_uri)
      assert found == user.id
    end
  end

  describe "the following browser" do
    setup do
      stub_account()
      user = federated_user()
      {:ok, follow} = Fediverse.follow_remote(user, "@them@social.example")
      %{user: user, follow: follow}
    end

    test "lists the member's follows with the account preloaded", %{user: user} do
      filters = Fediverse.browse_filters(%{})

      assert [row] = Fediverse.list_remote_follows_page(user, filters)
      assert %RemoteAccount{handle: "them"} = row.remote_account
      assert Fediverse.count_remote_follows(user, filters) == 1
    end

    test "searches name, handle and a pasted full address", %{user: user} do
      for term <- ["Them", "them", "social.example", "@them@social.example"] do
        filters = Fediverse.browse_filters(%{"q" => term})
        assert [_row] = Fediverse.list_remote_follows_page(user, filters), "no match for #{term}"
      end

      filters = Fediverse.browse_filters(%{"q" => "nobody"})
      assert [] = Fediverse.list_remote_follows_page(user, filters)
    end

    test "filters by server and offers the servers followed", %{user: user} do
      assert [%{host: "social.example", count: 1}] = Fediverse.remote_follow_hosts(user)

      filters = Fediverse.browse_filters(%{"server" => "social.example"})
      assert [_row] = Fediverse.list_remote_follows_page(user, filters)

      filters = Fediverse.browse_filters(%{"server" => "other.example"})
      assert [] = Fediverse.list_remote_follows_page(user, filters)
    end

    test "sorts by every offered column without raising", %{user: user} do
      for sort <- Fediverse.browse_sort_columns(), dir <- ~w(asc desc) do
        filters = Fediverse.browse_filters(%{"sort" => sort, "dir" => dir})
        assert [_row] = Fediverse.list_remote_follows_page(user, filters)
      end
    end

    test "shows nobody else's follows", %{user: user} do
      stranger = federated_user()
      assert [] = Fediverse.list_remote_follows_page(stranger, Fediverse.browse_filters(%{}))
      assert Fediverse.count_remote_follows(stranger) == 0
      assert Fediverse.count_remote_follows(user) == 1
    end
  end
end
