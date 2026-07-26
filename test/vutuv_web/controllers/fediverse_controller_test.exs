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

    test "advertises the featured collection (#1110)", %{conn: conn} do
      user = federated_user()

      body = conn |> get("/#{user.username}/actor") |> Map.fetch!(:resp_body) |> Jason.decode!()

      # Always named, even with nothing pinned — an actor that only sometimes
      # carries the field would make a remote profile depend on fetch timing.
      assert body["featured"] == Docs.featured_url(user)
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

  describe "GET /:slug/actor/collections/featured (issue #1110)" do
    defp featured(conn, user) do
      conn |> get("/#{user.username}/actor/collections/featured") |> Map.fetch!(:resp_body)
    end

    test "is an empty OrderedCollection while nothing is pinned", %{conn: conn} do
      user = federated_user()
      _post = create_post!(user, %{body: "not pinned"})

      body = conn |> featured(user) |> Jason.decode!()

      assert body["type"] == "OrderedCollection"
      assert body["id"] == Docs.featured_url(user)
      assert body["totalItems"] == 0
      assert body["orderedItems"] == []
    end

    test "carries the pinned post as a full Note", %{conn: conn} do
      user = federated_user()
      post = create_post!(user, %{body: "the one I am proud of"})
      {:ok, _} = Vutuv.Posts.pin_to_profile(user, post)

      body = conn |> featured(user) |> Jason.decode!()

      assert body["totalItems"] == 1
      assert [note] = body["orderedItems"]
      assert note["type"] == "Note"
      assert note["id"] == Docs.note_url(user, post.id)
      # Embedded in full, so a remote server renders it without a second fetch.
      assert note["content"] =~ "the one I am proud of"
      assert note["attributedTo"] == Docs.actor_url(user)
    end

    test "a pin the anonymous public may not see is absent", %{conn: conn} do
      user = federated_user()

      hidden =
        create_post!(user, %{body: "members only", denials: [%{"wildcard" => "logged_out"}]})

      {:ok, _} = Vutuv.Posts.pin_to_profile(user, hidden)

      body = conn |> featured(user) |> Jason.decode!()

      assert body["totalItems"] == 0
      refute body |> Jason.encode!() =~ "members only"
    end

    test "404s without the opt-in", %{conn: conn} do
      user = insert(:activated_user)

      conn = get(conn, "/#{user.username}/actor/collections/featured")
      assert conn.status == 404
    end
  end

  # A member who took part and then switched it off is *gone*, not merely
  # absent: the remote servers read a 410 on an actor they know as "this account
  # was deleted" and drop their copies of its posts, which is the closest the
  # protocol comes to honouring "forget me". So 410 is reserved for that one
  # case, and every other reason we withhold an actor keeps answering 404 — a
  # temporary suspension must never tell the network to delete the account.
  describe "410 Gone after a member opts out" do
    defp departed_user do
      user = federated_user()
      {:ok, user} = Vutuv.Accounts.update_user(user, %{"fediverse_followers?" => "false"})
      user
    end

    test "the actor, its collections and WebFinger all answer 410", %{conn: conn} do
      user = departed_user()

      for path <- [
            "/#{user.username}/actor",
            "/#{user.username}/actor/followers",
            "/#{user.username}/actor/outbox",
            "/.well-known/webfinger?resource=acct:#{user.username}@#{host()}"
          ] do
        assert conn |> recycle() |> get(path) |> Map.fetch!(:status) == 410
      end
    end

    test "the profile URL answers an AP Accept with 410 too", %{conn: conn} do
      user = departed_user()

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/#{user.username}")

      assert conn.status == 410
    end

    test "a delivery to the inbox is answered 410, so the remote drops the follow",
         %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = departed_user()

      conn = signed_post(conn, user, follow_activity(user), priv)

      assert conn.status == 410
      assert Fediverse.follower_count(user) == 0
    end

    test "a member who never took part stays a 404 — nothing to forget", %{conn: conn} do
      plain = insert(:activated_user)

      assert conn |> get("/#{plain.username}/actor") |> Map.fetch!(:status) == 404

      assert conn
             |> recycle()
             |> get("/.well-known/webfinger?resource=acct:#{plain.username}@#{host()}")
             |> Map.fetch!(:status) == 404
    end

    test "a temporarily hidden member stays a 404, never a 410", %{conn: conn} do
      for attrs <- [
            %{suspended_until: ~N[2099-01-01 00:00:00]},
            %{frozen_at: ~N[2026-07-01 00:00:00]},
            %{deactivated_at: ~N[2026-07-01 00:00:00]}
          ] do
        user = insert(:activated_user, Map.put(attrs, :fediverse_followers?, true))
        {:ok, _actor} = Fediverse.ensure_actor(user)

        assert conn |> recycle() |> get("/#{user.username}/actor") |> Map.fetch!(:status) == 404
      end
    end

    test "the installation switch being off is a 404, not the operator deleting members",
         %{conn: conn} do
      user = departed_user()
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      assert conn |> get("/#{user.username}/actor") |> Map.fetch!(:status) == 404
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

  describe "POST /:slug/actor/inbox — reactions from other networks (#1068)" do
    defp reaction_activity(type, object) do
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://social.example/activities/#{type}",
        "type" => type,
        "actor" => @remote_actor,
        "object" => object
      }
    end

    test "a signed Like on a public post is counted, and only once", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = federated_user()
      post = create_post!(user, %{body: "Reachable from anywhere."})
      note = Docs.note_url(user, post.id)

      conn = signed_post(conn, user, reaction_activity("Like", note), priv)
      assert conn.status == 202
      assert Fediverse.reaction_count(post.id) == 1

      conn = signed_post(recycle(conn), user, reaction_activity("Like", note), priv)
      assert conn.status == 202
      assert Fediverse.reaction_count(post.id) == 1
    end

    test "an Announce counts beside the Like from the same account", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = federated_user()
      post = create_post!(user, %{body: "Worth re-sharing."})
      note = Docs.note_url(user, post.id)

      signed_post(conn, user, reaction_activity("Like", note), priv)
      signed_post(recycle(conn), user, reaction_activity("Announce", note), priv)

      assert Fediverse.reaction_count(post.id) == 2
    end

    test "Undo(Like) removes it again", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = federated_user()
      post = create_post!(user, %{body: "Briefly applauded."})
      note = Docs.note_url(user, post.id)

      signed_post(conn, user, reaction_activity("Like", note), priv)
      assert Fediverse.reaction_count(post.id) == 1

      undo = reaction_activity("Undo", reaction_activity("Like", note))
      conn = signed_post(recycle(conn), user, undo, priv)

      assert conn.status == 202
      assert Fediverse.reaction_count(post.id) == 0
    end

    test "a reaction to a non-public post is acknowledged and dropped", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = federated_user()

      post =
        create_post!(user, %{body: "Members only.", denials: [%{"wildcard" => "logged_out"}]})

      conn =
        signed_post(conn, user, reaction_activity("Like", Docs.note_url(user, post.id)), priv)

      assert conn.status == 202
      assert Fediverse.reaction_count(post.id) == 0
    end
  end

  describe "POST /:slug/actor/inbox — replies from other networks (#1069, #1071)" do
    @public "https://www.w3.org/ns/activitystreams#Public"

    defp replying_user do
      user = insert(:activated_user, fediverse_followers?: true, fediverse_replies?: true)
      {:ok, _actor} = Fediverse.ensure_actor(user)
      user
    end

    defp create_note(note_url, opts \\ []) do
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://social.example/activities/create-1",
        "type" => "Create",
        "actor" => @remote_actor,
        "to" => Keyword.get(opts, :to, [@public]),
        "object" => %{
          "id" => Keyword.get(opts, :object_id, "#{@remote_actor}/statuses/1"),
          "type" => "Note",
          "inReplyTo" => note_url,
          "content" => Keyword.get(opts, :content, "<p>Sehe ich auch so.</p>"),
          "url" => "https://social.example/@alice/1",
          "to" => Keyword.get(opts, :to, [@public])
        }
      }
    end

    test "a signed public reply is stored under the post", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub, %{"preferredUsername" => "alice", "name" => "Alice Anders"})
      user = replying_user()
      post = create_post!(user, %{body: "Reachable from anywhere."})

      conn = signed_post(conn, user, create_note(Docs.note_url(user, post.id)), priv)

      assert conn.status == 202
      assert [note] = Fediverse.list_notes([post.id], user)[post.id]
      assert note.content_text == "Sehe ich auch so."
      assert note.handle == "alice"
      assert note.display_name == "Alice Anders"
      assert Fediverse.note_count(post.id) == 1
    end

    test "a member who did not switch replies on stores nothing", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      # federated_user/0 leaves fediverse_replies? at its default: off.
      user = federated_user()
      post = create_post!(user, %{body: "Reachable from anywhere."})

      conn = signed_post(conn, user, create_note(Docs.note_url(user, post.id)), priv)

      # Same 202 as a stored one, so a sender cannot probe the setting.
      assert conn.status == 202
      assert Fediverse.list_notes([post.id], user) == %{}
    end

    test "a reply addressed only to the member is stored, but privately", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = replying_user()
      post = create_post!(user, %{body: "Reachable from anywhere."})

      activity = create_note(Docs.note_url(user, post.id), to: [Docs.actor_url(user)])
      conn = signed_post(conn, user, activity, priv)

      assert conn.status == 202
      assert [%{audience: "direct"}] = Fediverse.list_notes([post.id], user)[post.id]
      # Nobody else sees it, and the public figure does not move.
      assert Fediverse.list_notes([post.id], nil) == %{}
      assert Fediverse.note_count(post.id) == 0
    end

    test "the author's Update rewrites the stored text", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = replying_user()
      post = create_post!(user, %{body: "Reachable from anywhere."})
      note_url = Docs.note_url(user, post.id)

      signed_post(conn, user, create_note(note_url), priv)

      update =
        note_url
        |> create_note(content: "<p>Korrektur: doch nicht.</p>")
        |> Map.put("type", "Update")

      conn = signed_post(recycle(conn), user, update, priv)

      assert conn.status == 202

      assert [%{content_text: "Korrektur: doch nicht."}] =
               Fediverse.list_notes([post.id], user)[post.id]
    end

    test "the author's Delete removes it, and does not touch the follow", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = replying_user()
      post = create_post!(user, %{body: "Reachable from anywhere."})
      note_url = Docs.note_url(user, post.id)

      signed_post(conn, user, follow_activity(user), priv)
      signed_post(recycle(conn), user, create_note(note_url), priv)
      assert Fediverse.note_count(post.id) == 1

      delete = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://social.example/activities/delete-1",
        "type" => "Delete",
        "actor" => @remote_actor,
        "object" => %{"id" => "#{@remote_actor}/statuses/1", "type" => "Tombstone"}
      }

      conn = signed_post(recycle(conn), user, delete, priv)

      assert conn.status == 202
      assert Fediverse.note_count(post.id) == 0
      # Deleting a note must leave the follow intact (only a Delete of the
      # actor itself drops that).
      assert Fediverse.follower_count(user) == 1
    end

    test "a reply to somebody else's post is acknowledged and dropped", %{conn: conn} do
      {priv, pub} = Keys.generate()
      stub_remote_actor(pub)
      user = replying_user()
      stranger = replying_user()
      post = create_post!(stranger, %{body: "Not yours to answer here."})

      conn = signed_post(conn, user, create_note(Docs.note_url(stranger, post.id)), priv)

      assert conn.status == 202
      assert Fediverse.note_count(post.id) == 0
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
