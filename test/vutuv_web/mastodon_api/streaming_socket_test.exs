defmodule VutuvWeb.MastodonApi.StreamingSocketTest do
  @moduledoc """
  Who may open the streaming websocket, and what comes down it.

  The socket is the one authenticated surface that does not go through the
  router or the HTTP plugs, so every gate the rest of the adapter gets for free
  has to be re-stated in `connect/1` — and nothing was covering it. That matters
  most for the two gates a request can never reach it by: the host test (a
  client that signed in on the main host has to be able to stream there, which
  needing the subdomain quietly prevented) and the identity switch (a member who
  turned app access off must lose the stream too, not only the REST calls).

  Driven through the `Phoenix.Socket.Transport` callbacks directly rather than
  over a real websocket: the callbacks *are* the contract, and a transport hands
  them exactly the map built here.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Organizations.OrganizationRole
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias VutuvWeb.MastodonApi.StreamingSocket

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  # What a transport hands `connect/1`: the query params it parsed and the
  # connect_info the endpoint was configured to collect.
  defp transport(params, host \\ "mastodon.localhost") do
    %{
      params: params,
      connect_info: %{uri: URI.parse("ws://#{host}/api/v1/streaming"), x_headers: []}
    }
  end

  # The envelope alone. Most events carry a JSON *string* as their payload, which
  # a client parses a second time; `delete` carries the bare id, so the two are
  # read apart here rather than guessing.
  defp decode_envelope({:text, json}), do: Jason.decode!(json)

  defp decode_frame(frame) do
    envelope = decode_envelope(frame)
    %{envelope | "payload" => Jason.decode!(envelope["payload"])}
  end

  describe "connect/1" do
    test "accepts a Mastodon read token on the subdomain" do
      user = insert(:activated_user)
      token = mastodon_token(user, ["read"])

      assert {:ok, state} = StreamingSocket.connect(transport(%{"access_token" => token}))
      assert state.user.id == user.id
      assert is_nil(state.organization)
    end

    # The gate the HTTP side applies is `client_host?/1`, which is both hosts.
    # Demanding the subdomain here let an app authenticate on the main host and
    # then never open a stream — which reads as a broken app, not as a rule.
    test "accepts the same token on the main host" do
      token = mastodon_token(insert(:activated_user), ["read"])

      assert {:ok, _state} =
               StreamingSocket.connect(transport(%{"access_token" => token}, "localhost"))
    end

    test "refuses a host that does not serve the adapter" do
      token = mastodon_token(insert(:activated_user), ["read"])

      assert StreamingSocket.connect(transport(%{"access_token" => token}, "example.org")) ==
               :error
    end

    # Both spellings are in the wild, and a client that can only pass the token
    # in the subprotocol header would otherwise never connect.
    test "accepts the token in the websocket subprotocol header" do
      token = mastodon_token(insert(:activated_user), ["read"])

      transport = %{
        params: %{},
        connect_info: %{
          uri: URI.parse("ws://mastodon.localhost/api/v1/streaming"),
          x_headers: [{"sec-websocket-protocol", " " <> token <> " "}]
        }
      }

      assert {:ok, _state} = StreamingSocket.connect(transport)
    end

    test "refuses a missing, unknown or wrongly scoped token" do
      user = insert(:activated_user)

      assert StreamingSocket.connect(transport(%{})) == :error
      assert StreamingSocket.connect(transport(%{"access_token" => "vutuv_at_nope"})) == :error

      write_only = mastodon_token(user, ["write:statuses"])
      assert StreamingSocket.connect(transport(%{"access_token" => write_only})) == :error
    end

    # A native vutuv API token is not a Mastodon grant, and the two vocabularies
    # stay apart on the socket exactly as they do on every request.
    test "refuses a token that was not issued to a Mastodon client" do
      user = allow_mastodon_clients(insert(:activated_user))
      plaintext = "vutuv_at_" <> Vutuv.ApiAuth.random_token()
      app = insert(:oauth_app, user: user, protocol: "vutuv", registered_scopes: ["read"])

      insert(:api_token,
        user: user,
        app: app,
        kind: "access",
        name: nil,
        scopes: ["read"],
        expires_at: nil,
        token_hash: Vutuv.ApiAuth.hash_token(plaintext)
      )

      assert StreamingSocket.connect(transport(%{"access_token" => plaintext})) == :error
    end

    test "refuses once the member switches app access off" do
      user = insert(:activated_user)
      token = mastodon_token(user, ["read"])

      assert {:ok, _state} = StreamingSocket.connect(transport(%{"access_token" => token}))

      deny_mastodon_clients(user)

      assert StreamingSocket.connect(transport(%{"access_token" => token})) == :error
    end

    test "resolves an organization identity from the token" do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      token = mastodon_token(owner, ["read"], organization)

      assert {:ok, state} = StreamingSocket.connect(transport(%{"access_token" => token}))
      assert state.organization.id == organization.id
    end

    # A token minted for a page is only as good as the role behind it, and the
    # socket is where that is easiest to forget: it is checked once and then the
    # connection lives for hours.
    test "refuses a page identity whose editorial role is gone" do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      token = mastodon_token(owner, ["read"], organization)

      Repo.delete!(
        Repo.get_by!(OrganizationRole, organization_id: organization.id, role: "publisher")
      )

      assert StreamingSocket.connect(transport(%{"access_token" => token})) == :error
    end
  end

  describe "the wire protocol" do
    setup do
      user = insert(:activated_user)
      token = mastodon_token(user, ["read"])
      {:ok, state} = StreamingSocket.connect(transport(%{"access_token" => token}))
      {:ok, state: state, user: user}
    end

    test "tracks subscribe and unsubscribe frames", %{state: state} do
      {:ok, state} =
        StreamingSocket.handle_in({~s({"type":"subscribe","stream":"user"}), []}, state)

      assert MapSet.member?(state.streams, "user")

      {:ok, state} =
        StreamingSocket.handle_in({~s({"type":"unsubscribe","stream":"user"}), []}, state)

      refute MapSet.member?(state.streams, "user")
    end

    # Garbage must not take the connection down: a client that sends a ping in a
    # shape we do not know keeps its stream.
    test "ignores a frame it cannot read", %{state: state} do
      assert {:ok, ^state} = StreamingSocket.handle_in({"not json", []}, state)
      assert {:ok, ^state} = StreamingSocket.handle_in({~s({"type":"hello"}), []}, state)
    end

    # Mastodon double-encodes: the frame is JSON whose `payload` is itself a
    # JSON *string*. A client parses the envelope, then parses the payload — get
    # this wrong and every event is silently dropped by the client.
    test "pushes a new post as a double-encoded update frame", %{state: state} do
      author = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{body: "Frisch geschrieben"})

      assert {:push, frame, ^state} =
               StreamingSocket.handle_info({:new_post, %{post_id: post.id}}, state)

      decoded = decode_frame(frame)

      assert decoded["stream"] == ["user"]
      assert decoded["event"] == "update"
      assert decoded["payload"]["id"] == post.id
      assert decoded["payload"]["content"] =~ "Frisch geschrieben"
    end

    test "stays silent about a post the viewer may not read", %{state: state} do
      author = insert(:activated_user)

      {:ok, post} =
        Posts.create_post(author, %{
          body: "Nur für Folgende",
          denials: [%{"wildcard" => "non_followers"}]
        })

      assert {:ok, ^state} = StreamingSocket.handle_info({:new_post, %{post_id: post.id}}, state)
    end

    test "stays silent about a post that is already gone", %{state: state} do
      assert {:ok, ^state} =
               StreamingSocket.handle_info(
                 {:new_post, %{post_id: Vutuv.UUIDv7.generate()}},
                 state
               )
    end

    # `delete` is the one event whose payload is a bare id rather than an object,
    # so it is worth pinning: a client that gets an object here leaves the post
    # on screen.
    test "pushes a deletion as the bare id", %{state: state} do
      id = Vutuv.UUIDv7.generate()

      assert {:push, frame, ^state} =
               StreamingSocket.handle_info({:post_deleted, %{post_id: id}}, state)

      # Not double-encoded, unlike every other event: Mastodon's `delete` payload
      # is the id itself. A client handed an object here leaves the post on
      # screen.
      assert decode_envelope(frame) == %{
               "stream" => ["user"],
               "event" => "delete",
               "payload" => id
             }
    end

    test "pushes a notification", %{state: state} do
      notification = %{id: "n-1", kind: "like", at: ~N[2026-08-17 10:00:00]}

      assert {:push, frame, ^state} =
               StreamingSocket.handle_info({:new_notification, notification}, state)

      decoded = decode_frame(frame)

      assert decoded["event"] == "notification"
      assert decoded["payload"]["type"] == "like"
      assert decoded["payload"]["id"] == "n-1"
    end

    test "ignores every other broadcast on the member's topic", %{state: state} do
      assert {:ok, ^state} = StreamingSocket.handle_info({:presence_pref, true}, state)
    end
  end

  # Mastodon's `update` carries a finished status: an attachment list has no
  # "still processing" state, and a client inserts the card once and never looks
  # again. So a post whose photo is still in the AI scan must not be announced —
  # otherwise that device shows it as text forever while every other surface has
  # the picture — and the release has to arrive as `status.update`, the event
  # Mastodon has for a status whose content changed after delivery.
  #
  # Calibrated against the unguarded socket: drop the `awaiting_image_release?/1`
  # test and the first case here goes green on an `update` it should not have
  # sent, which is the whole bug.
  describe "a post whose photo has not cleared the scan" do
    setup do
      user = insert(:activated_user)
      token = mastodon_token(user, ["read"])
      {:ok, state} = StreamingSocket.connect(transport(%{"access_token" => token}))

      author = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{body: "Mit Foto"})
      image = insert(:post_image, user: author, post: post, moderation: "pending")

      {:ok, state: state, post: post, image: image}
    end

    test "is not announced at all", %{state: state, post: post} do
      assert {:ok, ^state} = StreamingSocket.handle_info({:new_post, %{post_id: post.id}}, state)
    end

    test "arrives as status.update once the scan releases it", %{
      state: state,
      post: post,
      image: image
    } do
      image |> Ecto.Changeset.change(moderation: "approved") |> Repo.update!()

      assert {:push, frame, ^state} =
               StreamingSocket.handle_info(
                 {:post_images_settled, %{post_id: post.id, public?: true}},
                 state
               )

      decoded = decode_frame(frame)

      assert decoded["event"] == "status.update"
      assert decoded["payload"]["id"] == post.id
      assert [%{"type" => "image"}] = decoded["payload"]["media_attachments"]
    end

    # A second photo on the same post is still being scanned, so this is not the
    # release that finishes it; the one that settles the last picture is.
    test "stays silent while another photo on it is still pending", %{
      state: state,
      post: post
    } do
      assert {:ok, ^state} =
               StreamingSocket.handle_info(
                 {:post_images_settled, %{post_id: post.id, public?: false}},
                 state
               )
    end
  end

  # The author's own view over an app, which is where this is most confusing: the
  # website shows them a placeholder and a line of explanation, and a Mastodon
  # client has nowhere to put either. Their own pending photo cannot simply be
  # handed over — the image proxy authorises unreleased bytes from the *browser
  # session*, and an app fetches a media URL with no credentials at all, so it
  # would get the proxy's fail-closed 404 and render a broken image, which is
  # worse than a post with no photo. So the answer is the same event as for
  # everybody else, and `broadcast_images_settled/1` does reach the author's own
  # topic — this is the path that closes the gap for them.
  test "the author's own client gets their photo swapped in when the scan settles" do
    author = insert(:activated_user)
    token = mastodon_token(author, ["read"])
    {:ok, state} = StreamingSocket.connect(transport(%{"access_token" => token}))

    {:ok, post} = Posts.create_post(author, %{body: "Mein Foto"})
    image = insert(:post_image, user: author, post: post, moderation: "pending")

    # Nothing while it is pending, not even for the author.
    assert {:ok, ^state} = StreamingSocket.handle_info({:new_post, %{post_id: post.id}}, state)

    image |> Ecto.Changeset.change(moderation: "approved") |> Repo.update!()

    assert {:push, frame, ^state} =
             StreamingSocket.handle_info(
               {:post_images_settled, %{post_id: post.id, public?: true}},
               state
             )

    decoded = decode_frame(frame)

    assert decoded["event"] == "status.update"
    assert [%{"type" => "image"}] = decoded["payload"]["media_attachments"]
  end

  test "a post with a released photo is announced normally, with the photo" do
    user = insert(:activated_user)
    token = mastodon_token(user, ["read"])
    {:ok, state} = StreamingSocket.connect(transport(%{"access_token" => token}))

    author = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "Foto ist durch"})
    insert(:post_image, user: author, post: post, moderation: "approved")

    assert {:push, frame, ^state} =
             StreamingSocket.handle_info({:new_post, %{post_id: post.id}}, state)

    decoded = decode_frame(frame)

    assert decoded["event"] == "update"
    assert [%{"type" => "image"}] = decoded["payload"]["media_attachments"]
  end
end
