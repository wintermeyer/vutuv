defmodule VutuvWeb.FediverseControllerTest do
  # The ActivityPub surface: WebFinger discovery, the actor document and the
  # inbox (Follow -> Accept, Undo -> unfollow). async: false — remote-actor
  # fetching is stubbed through the application env.
  use VutuvWeb.ConnCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.HttpSignature
  alias Vutuv.Fediverse.Keys
  alias VutuvWeb.Fediverse.Docs

  @remote_actor "https://social.example/users/alice"
  @remote_key_id @remote_actor <> "#main-key"
  @remote_inbox @remote_actor <> "/inbox"
  @remote_shared "https://social.example/inbox"

  defp federated_user do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    user
  end

  defp host, do: VutuvWeb.Endpoint.host()

  defp stub_remote_actor(pub_pem, extra \\ %{}) do
    doc =
      Jason.encode!(
        Map.merge(
          %{
            "id" => @remote_actor,
            "type" => "Person",
            "inbox" => @remote_inbox,
            "endpoints" => %{"sharedInbox" => @remote_shared},
            "publicKey" => %{"id" => @remote_key_id, "publicKeyPem" => pub_pem}
          },
          extra
        )
      )

    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, doc)
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp signed_post(conn, user, activity, private_pem) do
    body = Jason.encode!(activity)
    path = "/#{user.username}/actor/inbox"

    headers =
      HttpSignature.signed_headers(
        "post",
        "https://#{host()}#{path}",
        body,
        @remote_key_id,
        private_pem
      )

    # Test conns forbid a host *header*; the controller falls back to
    # conn.host, so set that to the signed host instead.
    conn = %{conn | host: host()}

    headers
    |> Enum.reject(fn {name, _} -> name == "host" end)
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> put_req_header("content-type", "application/activity+json")
    |> post(path, body)
  end

  defp follow_activity(user) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://social.example/activities/1",
      "type" => "Follow",
      "actor" => @remote_actor,
      "object" => Docs.actor_url(user)
    }
  end

  # An Update / Delete the remote actor broadcasts about itself.
  defp lifecycle_activity(type, object) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://social.example/activities/#{type}",
      "type" => type,
      "actor" => @remote_actor,
      "object" => object
    }
  end

  defp existing_follower(user) do
    {:ok, _} =
      Fediverse.add_follower(user, %{
        actor_uri: @remote_actor,
        inbox_uri: @remote_inbox,
        handle: "alice",
        name: "Alice Example"
      })

    :ok
  end

  describe "GET /.well-known/webfinger" do
    test "resolves acct:handle@host to the actor for an opted-in member", %{conn: conn} do
      user = federated_user()

      conn = get(conn, "/.well-known/webfinger?resource=acct:#{user.username}@#{host()}")

      assert conn |> get_resp_header("content-type") |> hd() =~ "application/jrd+json"
      body = json_response(conn, 200)
      assert body["subject"] == "acct:#{user.username}@#{host()}"

      assert %{"href" => href, "type" => "application/activity+json"} =
               Enum.find(body["links"], &(&1["rel"] == "self"))

      assert href == Docs.actor_url(user)
    end

    test "404s for members without the opt-in, unknown handles and foreign hosts",
         %{conn: conn} do
      plain = insert(:activated_user)

      for resource <- [
            "acct:#{plain.username}@#{host()}",
            "acct:nobody@#{host()}",
            "acct:someone@elsewhere.example"
          ] do
        conn = get(recycle(conn), "/.well-known/webfinger?resource=#{resource}")
        assert conn.status == 404
      end
    end

    test "404s while federation is globally off", %{conn: conn} do
      user = federated_user()
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      conn = get(conn, "/.well-known/webfinger?resource=acct:#{user.username}@#{host()}")
      assert conn.status == 404
    end
  end

  describe "GET /:slug/actor" do
    test "serves the Person document as activity+json", %{conn: conn} do
      user = federated_user()

      conn = get(conn, "/#{user.username}/actor")

      assert get_resp_header(conn, "content-type") |> hd() =~ "application/activity+json"
      body = Jason.decode!(conn.resp_body)
      assert body["type"] == "Person"
      assert body["preferredUsername"] == user.username
      assert body["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    end

    test "404s without the opt-in", %{conn: conn} do
      user = insert(:activated_user)

      assert conn |> get("/#{user.username}/actor") |> Map.fetch!(:status) == 404
    end

    test "renders the member's alsoKnownAs aliases (#986)", %{conn: conn} do
      user = insert(:activated_user, fediverse_followers?: true, also_known_as: [@remote_actor])
      {:ok, _actor} = Fediverse.ensure_actor(user)

      body = conn |> get("/#{user.username}/actor") |> Map.fetch!(:resp_body) |> Jason.decode!()

      assert body["alsoKnownAs"] == [@remote_actor]
    end

    test "a moved account still serves its actor, now advertising movedTo (#986)", %{conn: conn} do
      user = insert(:activated_user, fediverse_followers?: true, moved_to: @remote_actor)
      {:ok, _actor} = Fediverse.ensure_actor(user)

      body = conn |> get("/#{user.username}/actor") |> Map.fetch!(:resp_body) |> Jason.decode!()

      assert body["movedTo"] == @remote_actor
    end

    test "followers and outbox are count-only collections", %{conn: conn} do
      user = federated_user()

      {:ok, _} =
        Fediverse.add_follower(user, %{actor_uri: @remote_actor, inbox_uri: @remote_inbox})

      followers = conn |> get("/#{user.username}/actor/followers") |> Map.fetch!(:resp_body)
      assert Jason.decode!(followers)["totalItems"] == 1

      outbox =
        conn |> recycle() |> get("/#{user.username}/actor/outbox") |> Map.fetch!(:resp_body)

      assert Jason.decode!(outbox)["type"] == "OrderedCollection"
    end
  end

  describe "POST /:slug/actor/inbox — Follow" do
    test "a signed Follow stores the follower and queues the Accept", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = federated_user()

      conn = signed_post(conn, user, follow_activity(user), priv)

      assert conn.status == 202
      assert Fediverse.follower_count(user) == 1

      [delivery] = Repo.all(Delivery)
      assert delivery.inbox_uri == @remote_inbox
      assert delivery.activity_json =~ ~s("type":"Accept")
      assert delivery.activity_json =~ "https://social.example/activities/1"
    end

    test "an unsigned Follow is rejected", %{conn: conn} do
      user = federated_user()

      conn =
        conn
        |> put_req_header("content-type", "application/activity+json")
        |> post("/#{user.username}/actor/inbox", Jason.encode!(follow_activity(user)))

      assert conn.status == 401
      assert Fediverse.follower_count(user) == 0
    end

    test "a Follow signed with the wrong key is rejected", %{conn: conn} do
      {_remote_priv, remote_pub} = Keys.generate()
      {other_priv, _} = Keys.generate()
      stub_remote_actor(remote_pub)
      user = federated_user()

      conn = signed_post(conn, user, follow_activity(user), other_priv)

      assert conn.status == 401
      assert Fediverse.follower_count(user) == 0
    end

    test "a spoofed actor (signature key belongs to someone else) is rejected", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = federated_user()

      spoofed = Map.put(follow_activity(user), "actor", "https://evil.example/users/mallory")

      conn = signed_post(conn, user, spoofed, priv)

      assert conn.status == 401
      assert Fediverse.follower_count(user) == 0
    end

    test "404s for a member without the opt-in", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = insert(:activated_user)

      conn = signed_post(conn, user, follow_activity(user), priv)

      assert conn.status == 404
    end
  end

  describe "POST /:slug/actor/inbox — Undo and noise" do
    test "Undo(Follow) removes the follower", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = federated_user()

      {:ok, _} =
        Fediverse.add_follower(user, %{actor_uri: @remote_actor, inbox_uri: @remote_inbox})

      undo = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://social.example/activities/2",
        "type" => "Undo",
        "actor" => @remote_actor,
        "object" => follow_activity(user)
      }

      conn = signed_post(conn, user, undo, priv)

      assert conn.status == 202
      assert Fediverse.follower_count(user) == 0
    end

    test "other signed activities are acknowledged and ignored", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = federated_user()

      like = %{
        "id" => "https://social.example/activities/3",
        "type" => "Like",
        "actor" => @remote_actor,
        "object" => "#{VutuvWeb.Endpoint.url()}/#{user.username}/posts/whatever"
      }

      conn = signed_post(conn, user, like, priv)

      assert conn.status == 202
      assert Repo.aggregate(Delivery, :count) == 0
    end
  end

  describe "POST /:slug/actor/inbox — blocked servers (#1067)" do
    setup do
      admin = insert(:activated_user, admin?: true)
      {:ok, {_blocked, _purged}} = Fediverse.block_instance(%{"host" => "social.example"}, admin)
      :ok
    end

    test "a blocked server is dropped before the signature is even checked", %{conn: conn} do
      user = federated_user()

      # No stub, no signature: if the blocklist did not cut in first, this would
      # be a 401. It is answered 202 and dropped, so the blocklist cannot be
      # enumerated from outside, and no remote actor document is fetched.
      conn =
        conn
        |> put_req_header("content-type", "application/activity+json")
        |> post("/#{user.username}/actor/inbox", Jason.encode!(follow_activity(user)))

      assert conn.status == 202
      assert Fediverse.follower_count(user) == 0
      assert Repo.aggregate(Delivery, :count) == 0
    end

    test "a correctly signed Follow from a blocked server still writes no row", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = federated_user()

      conn = signed_post(conn, user, follow_activity(user), priv)

      assert conn.status == 202
      assert Fediverse.follower_count(user) == 0
      assert Repo.aggregate(Delivery, :count) == 0
    end

    test "an unblocked server is unaffected", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = federated_user()

      [blocked] = Fediverse.list_blocked_instances()
      {:ok, _} = Fediverse.unblock_instance(blocked.id)

      conn = signed_post(conn, user, follow_activity(user), priv)

      assert conn.status == 202
      assert Fediverse.follower_count(user) == 1
    end
  end

  describe "POST /:slug/actor/inbox — remote actor lifecycle" do
    test "Update of the actor re-syncs the stored handle, name and inboxes", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub, %{"preferredUsername" => "alice_renamed", "name" => "Alice Renamed"})
      user = federated_user()
      :ok = existing_follower(user)

      activity = lifecycle_activity("Update", %{"id" => @remote_actor, "type" => "Person"})
      conn = signed_post(conn, user, activity, priv)

      assert conn.status == 202
      assert [follower] = Fediverse.list_followers(user)
      assert follower.handle == "alice_renamed"
      assert follower.name == "Alice Renamed"
      assert follower.shared_inbox_uri == @remote_shared
    end

    test "an Update from an actor following nobody here creates no follower", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub, %{"preferredUsername" => "alice"})
      user = federated_user()

      activity = lifecycle_activity("Update", %{"id" => @remote_actor, "type" => "Person"})
      conn = signed_post(conn, user, activity, priv)

      assert conn.status == 202
      assert Fediverse.follower_count(user) == 0
    end

    test "Delete of the actor itself removes the follower", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = federated_user()
      :ok = existing_follower(user)

      # Mastodon sends the bare actor URI as the object of an account Delete.
      conn = signed_post(conn, user, lifecycle_activity("Delete", @remote_actor), priv)

      assert conn.status == 202
      assert Fediverse.follower_count(user) == 0
    end

    test "Delete of one of the actor's notes leaves the follow intact", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = federated_user()
      :ok = existing_follower(user)

      tombstone = %{"id" => @remote_actor <> "/statuses/1", "type" => "Tombstone"}
      conn = signed_post(conn, user, lifecycle_activity("Delete", tombstone), priv)

      assert conn.status == 202
      assert Fediverse.follower_count(user) == 1
    end
  end

  describe "ActivityPub content negotiation" do
    test "the profile URL answers an AP Accept with the actor document", %{conn: conn} do
      user = federated_user()

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/#{user.username}")

      assert get_resp_header(conn, "content-type") |> hd() =~ "application/activity+json"
      assert Jason.decode!(conn.resp_body)["type"] == "Person"
    end

    test "a public post permalink answers an AP Accept with the Note", %{conn: conn} do
      user = federated_user()
      post = create_post!(user, %{body: "Hallo Fediverse"})

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/#{user.username}/posts/#{post.id}")

      body = Jason.decode!(conn.resp_body)
      assert body["type"] == "Note"
      assert body["content"] =~ "Hallo Fediverse"
    end

    test "a book review post's Note carries the review facts in its content", %{conn: conn} do
      user = federated_user()

      post =
        create_post!(user, %{
          body: "Sehr lesenswert.",
          review: %{
            "kind" => "book",
            "identifier" => "978-3-16-148410-0",
            "title" => "Refactoring",
            "creator" => "Martin Fowler",
            "year" => "2018",
            "medium" => "audiobook"
          }
        })

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/#{user.username}/posts/#{post.id}")

      content = Jason.decode!(conn.resp_body)["content"]

      # Remote software knows nothing of review cards, so the reviewed work's
      # facts ride inside the Note content itself.
      assert content =~ "Book review"
      assert content =~ "Refactoring"
      assert content =~ "Martin Fowler"
      assert content =~ "ISBN 978-3-16-148410-0"
      assert content =~ "https://www.amazon.de/dp/316148410X"
    end

    test "the profile head advertises the actor for opted-in members", %{conn: conn} do
      user = federated_user()

      html = conn |> get("/#{user.username}") |> html_response(200)

      assert html =~
               ~s(<link rel="alternate" type="application/activity+json" href="#{Docs.actor_url(user)}")
    end

    test "without the opt-in an AP Accept on the profile gets a 404, plain browsers HTML",
         %{conn: conn} do
      user = insert(:activated_user)

      ap =
        conn |> put_req_header("accept", "application/activity+json") |> get("/#{user.username}")

      assert ap.status == 404

      html = conn |> recycle() |> get("/#{user.username}") |> html_response(200)
      refute html =~ ~s(rel="alternate" type="application/activity+json")
    end
  end
end
