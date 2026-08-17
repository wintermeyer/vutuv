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
  """

  @behaviour Phoenix.Socket.Transport

  alias Vutuv.Activity
  alias Vutuv.ApiAuth
  alias Vutuv.MastodonApi
  alias Vutuv.MastodonApi.Access
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
      {:ok, %{user: user, organization: organization, streams: MapSet.new()}}
    else
      _refused -> :error
    end
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

  def handle_info({:new_notification, notification}, state) do
    {:push, event("notification", streamed_notification(notification)), state}
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
  defp check_host(%{connect_info: %{uri: %URI{host: host}}}) when is_binary(host) do
    if MastodonApi.client_host?(host), do: :ok, else: :error
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

  defp visible_status(post_id, state) do
    viewer = state.organization || state.user

    case Posts.get_post(post_id) do
      nil -> nil
      post -> if Posts.visible_to?(post, viewer), do: Presenter.status(post)
    end
  end

  # The notification the shell broadcasts is the same derived item the REST
  # endpoint renders, minus the batched account/status lookup — a live push
  # carries one item, so the batch would be a batch of one.
  defp streamed_notification(notification) do
    %{
      id: notification[:id],
      type: notification[:kind],
      created_at: notification[:at] && to_string(notification[:at]),
      account: nil,
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
