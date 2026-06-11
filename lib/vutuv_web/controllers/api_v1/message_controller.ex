defmodule VutuvWeb.ApiV1.MessageController do
  @moduledoc """
  Direct messages over the API — through `Vutuv.Chat`, so the message
  request model (a new conversation with a stranger is a request the
  recipient accepts or declines), blocking, freezes and the new-request
  rate limit apply exactly like the website.

  Reads (`messages:read`): `GET /conversations` (the sidebar: accepted
  conversations plus the viewer's own outgoing requests, and the incoming
  requests separately), `GET /conversations/:id/messages` (cursor-
  paginated thread, newest first).

  Writes (`messages:write`): `POST /users/:slug/messages` (find or open
  the conversation and send), `POST /conversations/:id/messages`,
  `POST /conversations/:id/accept` / `/decline` (incoming requests),
  `POST /conversations/:id/read` (clear the unread marker).

  Like the website, a declined request stays indistinguishable from an
  unanswered one for its sender: the status reads "pending" and sends are
  quietly accepted.
  """

  use VutuvWeb, :controller

  alias Vutuv.Chat
  alias Vutuv.Chat.{Conversation, Message}
  alias Vutuv.UUIDv7
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.ApiV1
  alias VutuvWeb.ApiV1.Problem

  plug(VutuvWeb.Plug.RequireScope, "messages:read" when action in [:index, :messages])

  plug(
    VutuvWeb.Plug.RequireScope,
    "messages:write"
    when action in [:send_to_user, :create_message, :accept, :decline, :mark_read]
  )

  # ── Reads ──

  def index(conn, _params) do
    me = conn.assigns.current_user

    ApiV1.send_json(conn, %{
      type: "conversations",
      conversations: me |> Chat.list_conversations() |> Enum.map(&conversation_entry/1),
      requests: me |> Chat.list_requests() |> Enum.map(&conversation_entry/1)
    })
  end

  def messages(conn, %{"id" => id} = params) do
    me = conn.assigns.current_user

    with uuid when is_binary(uuid) <- UUIDv7.cast_or_nil(id),
         %Conversation{} = conversation <- Chat.get_conversation(me, uuid) do
      case ApiV1.decode_cursor(params["cursor"]) do
        {:ok, cursor} ->
          page =
            Chat.messages_page(me, conversation.id,
              cursor: cursor,
              limit: ApiV1.page_limit(params, 30)
            )

          ApiV1.send_json(conn, %{
            type: "messages",
            conversation_id: conversation.id,
            messages: Enum.map(page.entries, &message_entry(&1, me)),
            more: page.more?,
            next_cursor: ApiV1.encode_cursor(page.more? && page.next_cursor)
          })

        :error ->
          Problem.send_problem(conn, 400, "Bad cursor",
            detail: "Pass the next_cursor value from a previous page, unmodified."
          )
      end
    else
      _missing -> Problem.not_found(conn)
    end
  end

  # ── Writes ──

  def send_to_user(conn, %{"slug" => slug} = params) do
    me = conn.assigns.current_user

    with {:ok, user} <- ApiV1.fetch_visible_user(slug, me),
         {:ok, conversation} <- Chat.find_or_create_conversation(me, user) do
      deliver(conn, me, conversation.id, params["body"])
    else
      :error ->
        Problem.not_found(conn)

      {:error, :self} ->
        Problem.send_problem(conn, 422, "Cannot message yourself")

      {:error, :not_activated} ->
        Problem.not_found(conn)

      {:error, :frozen} ->
        # Block or moderation freeze — one opaque refusal, like the website.
        Problem.send_problem(conn, 403, "Unavailable",
          detail: "This member cannot receive messages right now."
        )

      {:error, :rate_limited} ->
        Problem.send_problem(conn, 429, "Too many new requests",
          detail: "You opened too many new conversations recently. Wait and retry."
        )
    end
  end

  def create_message(conn, %{"id" => id} = params) do
    case UUIDv7.cast_or_nil(id) do
      nil -> Problem.not_found(conn)
      uuid -> deliver(conn, conn.assigns.current_user, uuid, params["body"])
    end
  end

  def accept(conn, %{"id" => id}), do: answer(conn, id, &Chat.accept_request/2)
  def decline(conn, %{"id" => id}), do: answer(conn, id, &Chat.decline_request/2)

  def mark_read(conn, %{"id" => id}) do
    me = conn.assigns.current_user

    with uuid when is_binary(uuid) <- UUIDv7.cast_or_nil(id),
         %Conversation{} = conversation <- Chat.get_conversation(me, uuid) do
      Chat.mark_read(me, conversation.id)
      send_resp(conn, 204, "")
    else
      _missing -> Problem.not_found(conn)
    end
  end

  # ── Internals ──

  defp deliver(conn, me, conversation_id, body) do
    case Chat.send_message(me, conversation_id, body) do
      {:ok, %Message{} = message} ->
        ApiV1.send_json(
          conn,
          sent_doc(message.id, message.body, message.inserted_at, conversation_id, me),
          201
        )

      {:ok, :dropped} ->
        # Declined/frozen conversations swallow sends silently (see
        # moduledoc) — same response shape, nothing persisted.
        ApiV1.send_json(
          conn,
          sent_doc(nil, body, NaiveDateTime.utc_now(:second), conversation_id, me),
          201
        )

      {:error, :not_participant} ->
        Problem.not_found(conn)

      {:error, :pending_limit} ->
        Problem.send_problem(conn, 409, "Request pending",
          detail: "Your request message is already out. Wait for an answer.",
          extra: %{reason: :pending_limit}
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        Problem.validation_failed(conn, changeset)
    end
  end

  defp sent_doc(id, body, at, conversation_id, me) do
    %{
      type: "message",
      id: id,
      conversation_id: conversation_id,
      body_markdown: body,
      sent_at: at,
      from: AgentDocs.person_ref(me),
      mine: true
    }
  end

  defp answer(conn, id, fun) do
    me = conn.assigns.current_user

    with uuid when is_binary(uuid) <- UUIDv7.cast_or_nil(id),
         {:ok, %Conversation{} = conversation} <- fun.(me, uuid) do
      ApiV1.send_json(conn, %{
        type: "conversation",
        id: conversation.id,
        status: conversation.status
      })
    else
      _missing -> Problem.not_found(conn)
    end
  end

  defp conversation_entry(%{conversation: conversation, other: other} = entry) do
    %{
      id: conversation.id,
      # A declined request reads "pending" to its sender, like the website.
      status: masked_status(conversation.status),
      with: AgentDocs.person_ref(other),
      last_message_at: entry.last_at,
      preview: entry.last_body && AgentDocs.excerpt(entry.last_body),
      unread: entry.unread
    }
  end

  defp masked_status("declined"), do: "pending"
  defp masked_status(status), do: status

  defp message_entry(%Message{} = message, me) do
    %{
      id: message.id,
      body_markdown: message.body,
      sent_at: message.inserted_at,
      from: AgentDocs.person_ref(message.sender),
      mine: message.sender_id == me.id
    }
  end
end
