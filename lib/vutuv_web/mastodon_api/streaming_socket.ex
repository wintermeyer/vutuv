defmodule VutuvWeb.MastodonApi.StreamingSocket do
  @moduledoc """
  Mastodon's streaming WebSocket, so a client learns about a new post or
  notification instead of polling for one.

  This is **not** a Phoenix channel: Mastodon has its own tiny protocol on the
  wire (a bare JSON frame per event, with the payload itself a JSON *string*),
  so it speaks `Phoenix.Socket.Transport` directly rather than borrowing the
  channel envelope a Mastodon client would not understand.

  What it carries is the `user` stream — the member's own timeline and
  notifications, fed by the `Vutuv.Activity` PubSub topic the website's shell
  already listens on. `public` and `hashtag` streams are accepted and stay
  silent: vutuv broadcasts nothing site-wide, and a subscription that quietly
  never fires is a better answer than an error a client would retry forever.

  **The token is re-verified on connect and the identity re-derived**, exactly
  as on an HTTP request — a socket that outlives a withdrawn role would be the
  one place the per-request check does not reach. What it cannot do is notice a
  withdrawal *mid-connection*; the stream carries no private content of its own
  (every payload is a status the member may already read), so the exposure is
  the connection's lifetime, not the token's.

  One thing a payload does carry past that lifetime is a picture's capability
  (`VutuvWeb.RemoteMediaToken`), which outlives the socket by days. It is bound
  to the member and re-checked against their standing and the picture's audience
  on every image request, so a withdrawal reaches it there even though it cannot
  reach it here.
  """

  @behaviour Phoenix.Socket.Transport

  alias Vutuv.Activity
  alias Vutuv.ApiAuth
  alias Vutuv.MastodonApi
  alias Vutuv.MastodonApi.Access
  alias Vutuv.MastodonApi.Notifications
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.MastodonApi.Scopes
  alias Vutuv.Posts

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(%{params: params} = transport) do
    with :ok <- check_host(transport),
         token when is_binary(token) <- access_token(params, transport),
         {:ok, api_token, user} <- ApiAuth.verify_token(token),
         true <- mastodon_token?(api_token),
         {:ok, organization} <- Access.authorize_token(api_token, user),
         true <- Scopes.granted?(api_token.scopes, "read:statuses"),
         ["read:statuses"] <- Access.allowed_scopes(user, organization, ["read:statuses"]) do
      {:ok,
       %{
         user: user,
         organization: organization,
         streams: MapSet.new(),
         notifications?: granted?(user, organization, api_token, "read:notifications")
       }}
    else
      _refused -> :error
    end
  end

  # The user stream carries two things a client asks for with two scopes, and
  # `read:statuses` is the only one connecting requires (Mastodon lets a client
  # open the socket with it alone). So whether notifications go down it is asked
  # separately — a token authorized to read this member's posts was never
  # authorized to read who liked them.
  defp granted?(user, organization, api_token, scope) do
    Scopes.granted?(api_token.scopes, scope) and
      Access.allowed_scopes(user, organization, [scope]) == [scope]
  end

  @impl true
  def init(state) do
    Activity.subscribe(state.organization || state.user.id)

    # A client may name its stream in the connect query instead of sending a
    # subscribe frame; both shapes are in the wild.
    {:ok, state}
  end

  @impl true
  def handle_in({text, _opts}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "subscribe", "stream" => stream}} ->
        {:ok, %{state | streams: MapSet.put(state.streams, stream)}}

      {:ok, %{"type" => "unsubscribe", "stream" => stream}} ->
        {:ok, %{state | streams: MapSet.delete(state.streams, stream)}}

      _other ->
        {:ok, state}
    end
  end

  @impl true
  def handle_info({:new_post, %{post_id: post_id}}, state) do
    case visible_status(post_id, state) do
      nil -> {:ok, state}
      status -> {:push, event("update", status), state}
    end
  end

  # The photos on a post the client may already have finished the AI scan. That
  # is `status.update` and not `update`: Mastodon uses it for a status whose
  # content changed after it was delivered, which is exactly what happened, and
  # a client replaces the card in place instead of inserting a second copy.
  #
  # Without this a picture would simply never arrive. `update` announces a
  # status **once**, and a client does not revisit it — so a post streamed while
  # its photo was still pending would sit there as text forever, on that device,
  # while every other surface shows the picture. `public?: false` means a second
  # photo on the same post is still being scanned; the release that settles the
  # last one is the one that carries the news.
  def handle_info({:post_images_settled, %{post_id: post_id, public?: true}}, state) do
    case visible_status(post_id, state) do
      nil -> {:ok, state}
      status -> {:push, event("status.update", status), state}
    end
  end

  def handle_info({:new_notification, notification}, state) do
    if state.notifications? and Notifications.mapped?(notification) do
      {:push, event("notification", streamed_notification(notification)), state}
    else
      {:ok, state}
    end
  end

  def handle_info({:post_deleted, %{post_id: post_id}}, state) do
    # `delete` carries the bare id as its payload, not an object.
    {:push, frame(%{stream: ["user"], event: "delete", payload: post_id}), state}
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # The streaming socket is mounted on the shared endpoint, which has no host
  # scoping of its own, so the host is checked here — the adapter must not
  # become reachable from an origin that does not serve it.
  #
  # The same test the HTTP gate applies (`client_host?/1`), not `api_host()`
  # alone: a client that signed in on the main host keeps talking to the main
  # host, so demanding the subdomain here let it authenticate and then never
  # open a stream — the one failure a member reads as "the app is broken"
  # rather than as a missing feature.
  # `enabled?/0` as well as the host, for the same reason `Plugs.MastodonApiGate`
  # checks both: an operator who sets `MASTODON_API_ENABLED=false` has turned the
  # adapter off, and an adapter whose HTTP half 404s while its websocket still
  # accepts connections is not off. The socket is mounted on the shared endpoint
  # and so is reached by neither the gate nor the router.
  defp check_host(%{connect_info: %{uri: %URI{host: host}}}) when is_binary(host) do
    if MastodonApi.enabled?() and MastodonApi.client_host?(host), do: :ok, else: :error
  end

  defp check_host(_transport), do: :error

  # Mastodon clients pass the token either as a query parameter or in the
  # websocket subprotocol header, and both are common enough to accept.
  defp access_token(%{"access_token" => token}, _transport) when is_binary(token), do: token

  defp access_token(_params, %{connect_info: %{x_headers: headers}}) do
    Enum.find_value(headers, fn
      {"sec-websocket-protocol", value} -> String.trim(value)
      _other -> nil
    end)
  end

  defp access_token(_params, _transport), do: nil

  defp mastodon_token?(%{app: %{protocol: "mastodon"}}), do: true
  defp mastodon_token?(_token), do: false

  # A post whose pictures have not cleared the scan is **not** announced, even
  # when it is otherwise visible. Mastodon's `update` carries a finished status:
  # its attachment list has no "still processing" state (only the media endpoint
  # does), so announcing one now would put a permanently text-only card in the
  # client — the `status.update` above is what carries it once the scan settles.
  #
  # This does not rely on the fan-out being deferred elsewhere, and deliberately
  # so: today `Posts.broadcast_images_settled/1` is what tells a follower about a
  # held post, but that is a property of the post pipeline and not a promise to
  # this socket.
  #
  # Asked **by id**, not on the struct in hand. `awaiting_image_release?/1`
  # answers `false` for an unloaded `:images` association, so passing a post
  # whose preloads someone later trims would silently open this gate — and the
  # failure would be an unvetted picture's absence going unnoticed rather than a
  # crash. The id clause preloads for itself. That is one extra read on an event
  # a member sees a handful of times a day.
  defp visible_status(post_id, state) do
    viewer = state.organization || state.user

    case Posts.get_post(post_id) do
      nil ->
        nil

      post ->
        # `one_status/2`, not the bare `status/1`: a pushed status lands in the
        # same client cache as the REST answers, so it has to carry the
        # viewer's own engagement flags and the author's account counts too —
        # zeroes here would overwrite the figures the batch just filled.
        if Posts.visible_to?(post, viewer) and not Posts.awaiting_image_release?(post_id),
          do: Presenter.one_status(post, viewer)
    end
  end

  # The notification the shell broadcasts is the same derived item the REST
  # endpoint renders, and it goes out in the same vocabulary: the **Mastodon**
  # type from `Vutuv.MastodonApi.Notifications`, never the raw vutuv kind. A
  # socket that sent `"like"` where `/api/v1/notifications` says `"favourite"`
  # made one notification two different things depending on how the client heard
  # about it, and sent kinds Mastodon has no type for at all.
  #
  # The account is looked up rather than left nil: a Notification entity without
  # one is not a Notification, and a client reading `account.acct` off nil is a
  # crash on the client's side of a contract we wrote. One row for one item is
  # what the batch loader would have cost anyway.
  defp streamed_notification(notification) do
    %{
      id: notification[:id],
      type: Notifications.type(notification),
      created_at: notification[:at] && to_string(notification[:at]),
      account: Notifications.account(notification),
      status: nil
    }
  end

  defp event(name, payload), do: frame(%{stream: ["user"], event: name, payload: payload})

  # Mastodon double-encodes: the frame is JSON whose `payload` is itself a JSON
  # string. A client parses the envelope, then parses the payload.
  defp frame(%{payload: payload} = message) when not is_binary(payload) do
    frame(%{message | payload: Jason.encode!(payload)})
  end

  defp frame(message), do: {:text, Jason.encode!(message)}
end
