defmodule VutuvWeb.MessageLive.Index do
  @moduledoc """
  Messages page, backed by `Vutuv.Chat` (persisted 1:1 conversations).

  The sidebar lists the member's conversations plus incoming message requests
  (pending conversations from strangers) with Accept/Decline. The thread is a
  cursor-paginated LiveView stream (latest page on open, older on demand);
  messages sent in one session appear instantly in every other session on the
  same conversation (PubSub on `"conversation:<id>"`), online dots and typing
  indicators run on `Phoenix.Presence`, and opening a thread persists the read
  marker, which also clears the unread badge in the shell. On small screens
  `/messages` shows the list and `/messages/:id` the thread with a back link.

  Authorization is real: the topic is only subscribed after
  `Chat.get_conversation/2` confirms the viewer is a participant, so nobody
  can subscribe to (or read) someone else's conversation.
  """
  use VutuvWeb, :live_view

  alias Vutuv.Chat
  alias Vutuv.Chat.{Conversation, Message}
  alias VutuvWeb.Presence

  @typing_clear_ms 2500
  @page_size 30

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      # The activity topic carries {:new_message, %{conversation_id: ...}}
      # for conversations other than the open one — it keeps the sidebar live.
      Vutuv.Activity.subscribe(user.id)
      # Online presence: ShellLive (embedded on this page too) is the sole
      # tracker, so here we only watch the shared topic to keep a conversation
      # partner's dot/header status live.
      Presence.subscribe_online()
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Messages"))
     |> assign(:user_name, display_name(user))
     |> assign(:typing_tokens, %{})
     |> assign(:online_ids, Presence.online_ids())
     |> assign(:conversation, nil)
     |> assign(:other, nil)
     |> assign(:more?, false)
     |> assign(:cursor, nil)
     |> assign_lists()
     |> stream(:messages, [], dom_id: &"message-#{&1.id}")
     |> assign_form()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:conversation, nil) |> assign(:other, nil)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    user = socket.assigns.current_user

    case Chat.get_conversation(user, id) do
      nil ->
        push_navigate(socket, to: ~p"/messages")

      %Conversation{} = conversation ->
        if connected?(socket) do
          Chat.subscribe(conversation.id)
          Chat.mark_read(user, conversation.id)
        end

        page = Chat.messages_page(user, conversation.id, limit: @page_size)

        socket
        |> assign(:conversation, conversation)
        |> assign(:other, Chat.other_user(conversation, user.id))
        |> assign(:more?, page.more?)
        |> assign(:cursor, page.next_cursor)
        |> stream(:messages, Enum.reverse(page.entries), reset: true)
        # Re-list so this conversation's unread badge zeroes right away.
        |> assign_lists()
    end
  end

  # Entry point for the profile "Message" button: find or create the
  # conversation with that member, then land in its thread.
  defp apply_action(socket, :new, %{"slug" => slug}) do
    case Vutuv.Accounts.get_user_by_username(slug) do
      nil ->
        socket
        |> put_flash(:error, gettext("Member not found."))
        |> push_navigate(to: ~p"/messages")

      other ->
        case Chat.find_or_create_conversation(socket.assigns.current_user, other) do
          {:ok, conversation} ->
            push_navigate(socket, to: ~p"/messages/#{conversation.id}")

          {:error, :rate_limited} ->
            socket
            |> put_flash(:error, gettext("Too many new conversations. Please try again later."))
            |> push_navigate(to: ~p"/messages")

          {:error, _reason} ->
            socket
            |> put_flash(:error, gettext("This member cannot receive messages."))
            |> push_navigate(to: ~p"/messages")
        end
    end
  end

  ## Events

  @impl true
  def handle_event("send", %{"message" => %{"body" => body}}, socket) do
    body = String.trim(body)

    if body == "" or is_nil(socket.assigns.conversation) do
      {:noreply, socket}
    else
      case Chat.send_message(socket.assigns.current_user, socket.assigns.conversation.id, body) do
        # The echo arrives via the conversation topic broadcast, so all
        # sessions (including this one) render it the same way.
        {:ok, %Message{}} ->
          {:noreply, socket |> refresh_conversation() |> assign_form()}

        # Declined conversation: drop silently — for the sender everything
        # looks exactly like an unanswered request.
        {:ok, :dropped} ->
          {:noreply, assign_form(socket)}

        {:error, :pending_limit} ->
          {:noreply, socket |> refresh_conversation()}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, put_flash(socket, :error, gettext("This message could not be sent."))}

        {:error, :not_participant} ->
          {:noreply, push_navigate(socket, to: ~p"/messages")}
      end
    end
  end

  def handle_event("typing", _params, socket) do
    if socket.assigns.conversation do
      Chat.broadcast_typing(socket.assigns.conversation.id, socket.assigns.user_name)
    end

    {:noreply, socket}
  end

  def handle_event("accept", %{"id" => id}, socket) do
    case Chat.accept_request(socket.assigns.current_user, id) do
      {:ok, %Conversation{} = conversation} ->
        socket = assign_lists(socket)

        socket =
          if active?(socket, conversation.id),
            do: assign(socket, :conversation, conversation),
            else: socket

        {:noreply, socket}

      {:error, :not_recipient} ->
        {:noreply, socket}
    end
  end

  def handle_event("decline", %{"id" => id}, socket) do
    case Chat.decline_request(socket.assigns.current_user, id) do
      {:ok, %Conversation{} = conversation} ->
        if active?(socket, conversation.id) do
          {:noreply, push_navigate(socket, to: ~p"/messages")}
        else
          {:noreply, assign_lists(socket)}
        end

      {:error, :not_recipient} ->
        {:noreply, socket}
    end
  end

  def handle_event("load-older", _params, socket) do
    page =
      Chat.messages_page(socket.assigns.current_user, socket.assigns.conversation.id,
        limit: @page_size,
        cursor: socket.assigns.cursor
      )

    {:noreply,
     socket
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> stream(:messages, Enum.reverse(page.entries), at: 0)}
  end

  # Block the other member straight from the thread — the moment unwanted
  # contact usually arrives. Same Social.block_user/2 path as the profile
  # control: it severs follows + the connection and freezes this conversation,
  # so it drops off the list (list_conversations hides frozen ones); land back
  # there with a notice. block_user/2 is idempotent and never refuses here
  # (the other party is, by construction, not the current user).
  def handle_event("block", _params, socket) do
    case socket.assigns.other do
      nil ->
        {:noreply, socket}

      other ->
        {:ok, _block} = Vutuv.Social.block_user(socket.assigns.current_user, other)

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("You blocked @%{slug}. You can undo this on your blocked list.",
             slug: other.username
           )
         )
         |> push_navigate(to: ~p"/messages")}
    end
  end

  ## PubSub

  @impl true
  # Full message on the open conversation's topic (sender or recipient side).
  def handle_info({:new_message, %Message{} = message}, socket) do
    user = socket.assigns.current_user

    # The member is watching the message arrive, so it is already read; this
    # also broadcasts :messages_read, keeping the shell badge at zero.
    if message.sender_id != user.id && socket.assigns.conversation do
      Chat.mark_read(user, socket.assigns.conversation.id)
    end

    {:noreply,
     socket
     |> stream_insert(:messages, message)
     |> refresh_conversation()
     |> assign_lists()}
  end

  # A message in this thread was frozen by moderation: pull it off the
  # recipient's screen right away; the sender's copy re-renders dimmed with
  # the "under review" note.
  def handle_info({:message_frozen, %{message_id: message_id, sender_id: sender_id}}, socket) do
    if socket.assigns.current_user.id == sender_id do
      case Vutuv.Repo.get(Message, message_id) do
        nil ->
          {:noreply, socket}

        message ->
          {:noreply, stream_insert(socket, :messages, Vutuv.Repo.preload(message, :sender))}
      end
    else
      {:noreply, stream_delete_by_dom_id(socket, :messages, "message-#{message_id}")}
    end
  end

  # A message was deleted (moderation): drop the bubble from any open thread
  # (no-op when it isn't streamed here) and refresh the sidebar preview.
  def handle_info({:message_deleted, %{message_id: message_id}}, socket) do
    {:noreply,
     socket
     |> stream_delete_by_dom_id(:messages, "message-#{message_id}")
     |> assign_lists()}
  end

  # Activity event: a message arrived in some conversation of mine. The open
  # conversation's own topic already delivered its copy above, so only
  # messages landing elsewhere need a sidebar refresh.
  def handle_info({:new_message, %{conversation_id: conversation_id}}, socket) do
    if active?(socket, conversation_id) do
      {:noreply, socket}
    else
      {:noreply, assign_lists(socket)}
    end
  end

  # A request was accepted: the initiator's open thread must swap its "not
  # accepted yet" placeholder for a live composer, so re-read the conversation
  # it is viewing. (Declines never broadcast — see Vutuv.Chat.)
  def handle_info({:conversation_updated, conversation_id}, socket) do
    if active?(socket, conversation_id) do
      {:noreply, socket |> refresh_conversation() |> assign_lists()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:typing, name}, socket) do
    # Token-guarded clear: every keystroke refreshes the token, and only the
    # newest scheduled clear wins — otherwise the first timer would hide the
    # indicator after 2.5s even while the other person is still typing. Who is
    # typing right now is exactly the keyset of this map.
    token = make_ref()
    Process.send_after(self(), {:clear_typing, name, token}, @typing_clear_ms)

    {:noreply, update(socket, :typing_tokens, &Map.put(&1, name, token))}
  end

  def handle_info({:clear_typing, name, token}, socket) do
    if socket.assigns.typing_tokens[name] == token do
      {:noreply, update(socket, :typing_tokens, &Map.delete(&1, name))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :online_ids, Presence.online_ids())}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  ## Helpers

  defp assign_lists(socket) do
    user = socket.assigns.current_user

    socket
    |> assign(:conversations, Chat.list_conversations(user))
    |> assign(:requests, Chat.list_requests(user))
  end

  # The active conversation's status and last_message_at drive the composer
  # (waiting hint, request banner), so re-read them after sends and accepts.
  defp refresh_conversation(socket) do
    case socket.assigns.conversation do
      nil ->
        socket

      %Conversation{id: id} ->
        case Chat.get_conversation(socket.assigns.current_user, id) do
          nil -> socket
          conversation -> assign(socket, :conversation, conversation)
        end
    end
  end

  defp active?(socket, conversation_id),
    do: match?(%Conversation{id: ^conversation_id}, socket.assigns.conversation)

  defp assign_form(socket), do: assign(socket, :form, to_form(%{"body" => ""}, as: :message))

  defp display_name(nil), do: gettext("Deleted account")

  defp display_name(user) do
    case VutuvWeb.UserHelpers.full_name(user) do
      "" -> gettext("Member")
      name -> name
    end
  end

  defp mine?(%Message{sender_id: sender_id}, user_id),
    do: not is_nil(sender_id) and sender_id == user_id

  # The Accept/Decline pair, shared by the sidebar request rows and the
  # in-thread request banner.
  attr(:id, :string, required: true)
  attr(:class, :string, default: nil)

  defp request_actions(assigns) do
    ~H"""
    <div class={["flex gap-2", @class]}>
      <button
        phx-click="accept"
        phx-value-id={@id}
        class="rounded-lg bg-brand-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-brand-700"
      >
        {gettext("Accept")}
      </button>
      <button
        phx-click="decline"
        phx-value-id={@id}
        class="rounded-lg bg-slate-100 px-3 py-1.5 text-xs font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
      >
        {gettext("Decline")}
      </button>
    </div>
    """
  end

  defp typing_label(typing_tokens) do
    case Map.keys(typing_tokens) do
      [] -> nil
      [name] -> gettext("%{name} is typing…", name: name)
      names -> gettext("%{names} are typing…", names: Enum.join(names, ", "))
    end
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <div id="messages" class="flex h-[calc(100vh-9rem)] gap-4 py-6 md:h-[calc(100vh-7rem)]">
      <h1 class="sr-only">{gettext("Messages")}</h1>
      <%!-- Conversation list. Full-width on mobile while no thread is open;
            once one is, the thread takes over and the list moves behind the
            back link (md+ always shows both). --%>
      <aside class={[
        "w-full shrink-0 overflow-y-auto rounded-2xl bg-white ring-1 ring-slate-200 md:block md:w-64 dark:bg-slate-900 dark:ring-slate-800",
        @conversation && "hidden"
      ]}>
        <div :if={@requests != []} id="requests" class="border-b border-slate-200 dark:border-slate-800">
          <h2 class="px-4 pt-3 text-sm font-semibold uppercase tracking-wide text-slate-500">
            {gettext("Requests")}
          </h2>
          <ul>
            <li :for={entry <- @requests} class="px-4 py-3">
              <.link navigate={~p"/messages/#{entry.conversation.id}"} class="flex items-center gap-3">
                <.avatar user={entry.other} size="sm" />
                <span class="min-w-0">
                  <span class="block truncate text-sm font-medium text-slate-800 dark:text-slate-100">
                    {display_name(entry.other)}
                  </span>
                  <span class="block truncate text-xs text-slate-600 dark:text-slate-400">{entry.last_body}</span>
                </span>
              </.link>
              <.request_actions id={entry.conversation.id} class="mt-2" />
            </li>
          </ul>
        </div>

        <ul>
          <li :for={entry <- @conversations}>
            <.link
              navigate={~p"/messages/#{entry.conversation.id}"}
              class={[
                "flex items-center gap-3 px-4 py-3 hover:bg-slate-50 dark:hover:bg-slate-800",
                @conversation && @conversation.id == entry.conversation.id &&
                  "bg-brand-50 dark:bg-brand-900/30"
              ]}
            >
              <span class="relative shrink-0">
                <.avatar user={entry.other} size="sm" />
                <.presence_dot online={Presence.online?(@online_ids, entry.other.id)} size="sm" />
              </span>
              <span class="min-w-0 flex-1">
                <span class="block truncate text-sm font-medium text-slate-800 dark:text-slate-100">
                  {display_name(entry.other)}
                </span>
                <span class="block truncate text-xs text-slate-600 dark:text-slate-400">{entry.last_body}</span>
              </span>
              <.count_badge count={entry.unread} />
            </.link>
          </li>
        </ul>

        <div :if={@conversations == [] && @requests == []} class="px-4 py-6 text-sm text-slate-600 dark:text-slate-400">
          <p>{gettext("No conversations yet.")}</p>
          <p class="mt-1">{gettext("Open someone's profile to message them.")}</p>
          <p class="mt-2">
            <.link navigate={~p"/search"} class="font-semibold text-brand-600 hover:text-brand-700">
              {gettext("Find members")}
            </.link>
          </p>
        </div>
      </aside>

      <%!-- Active thread --%>
      <section
        :if={@conversation}
        class="flex min-w-0 flex-1 flex-col rounded-2xl bg-white ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800"
      >
        <header class="flex items-center justify-between border-b border-slate-200 px-4 py-3 dark:border-slate-800">
          <div class="flex min-w-0 items-center gap-3">
            <.link
              id="back-to-list"
              navigate={~p"/messages"}
              class="shrink-0 text-slate-600 dark:text-slate-400 hover:text-slate-600 md:hidden dark:hover:text-slate-200"
              aria-label={gettext("Back to conversations")}
            >
              <svg class="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M15 19l-7-7 7-7" />
              </svg>
            </.link>
            <.link navigate={~p"/#{@other}"} class="flex min-w-0 items-center gap-2">
              <.avatar user={@other} size="sm" />
              <h1 class="truncate font-semibold text-slate-800 dark:text-slate-100">
                {display_name(@other)}
              </h1>
            </.link>
          </div>
          <div class="flex items-center gap-2">
            <%= if typing_label(@typing_tokens) do %>
              <span class="text-xs font-medium text-brand-600 dark:text-brand-400">{typing_label(@typing_tokens)}</span>
            <% else %>
              <span
                :if={Presence.online?(@online_ids, @other.id)}
                id="other-online"
                class="text-xs text-emerald-600 dark:text-emerald-400"
              >
                {gettext("Online")}
              </span>
            <% end %>

            <%!-- Calm overflow menu: blocking is reachable right where unwanted
            contact arrives, without shouting. The shared <.card_menu> (native
            <details data-menu>; app.js closes it on outside click and Escape).
            Blocking severs follows + the connection, freezes this conversation
            and stops all interaction both ways; unblocking restores nothing. --%>
            <.card_menu :if={@other} id="thread-menu">
              <:item
                id="block-from-thread"
                click="block"
                danger
                confirm={
                  gettext(
                    "Block @%{slug}? This removes any follows and connection between you, closes your conversation, and prevents all interaction in both directions. Unblocking will not restore what was removed.",
                    slug: @other.username
                  )
                }
              >
                {gettext("Block @%{slug}", slug: @other.username)}
              </:item>
            </.card_menu>
          </div>
        </header>

        <div :if={@more?} class="border-b border-slate-200 py-2 text-center dark:border-slate-800">
          <button id="load-older" phx-click="load-older" class="text-sm font-semibold text-brand-600 hover:text-brand-700">
            {gettext("Load older messages")}
          </button>
        </div>

        <div id="message-thread" phx-update="stream" phx-hook="ScrollBottom" class="flex-1 space-y-2 overflow-y-auto p-4">
          <div
            :for={{dom_id, m} <- @streams.messages}
            id={dom_id}
            class={["group flex items-center gap-1.5", mine?(m, @current_user.id) && "justify-end"]}
          >
            <div class={[
              "max-w-[75%] break-words rounded-2xl px-3 py-2 text-sm",
              "[&_a]:underline [&_a]:break-all [&_blockquote]:border-l-2 [&_blockquote]:pl-2",
              "[&_code]:rounded [&_code]:px-1 [&_code]:font-mono [&_code]:text-[0.85em]",
              "[&_ol]:list-decimal [&_ol]:pl-4 [&_p+p]:mt-1 [&_ul]:list-disc [&_ul]:pl-4",
              m.frozen_at && "opacity-60",
              if(mine?(m, @current_user.id),
                do: "bg-brand-600 text-white [&_a]:text-white [&_code]:bg-white/20",
                else:
                  "bg-slate-100 text-slate-800 dark:bg-slate-800 dark:text-slate-100 [&_a]:text-brand-700 dark:[&_a]:text-brand-300 [&_code]:bg-black/10 dark:[&_code]:bg-white/10"
              )
            ]}>
              <span :if={not mine?(m, @current_user.id)} class="mb-0.5 block text-xs font-semibold text-brand-700 dark:text-brand-300">
                {display_name(m.sender)}
              </span>
              {VutuvWeb.Markdown.render(m.body)}
              <%!-- Only the sender ever sees a frozen message; tell them why
              the other side stopped reacting to it. --%>
              <span :if={m.frozen_at} class="mt-1 block text-[10px] font-semibold text-white/80">
                ⚑ <.link navigate={~p"/moderation/cases"} class="underline">{gettext("Hidden: reported, under review")}</.link>
              </span>
              <.local_time
                id={"#{dom_id}-at"}
                at={m.inserted_at}
                format="%d.%m.%Y %H:%M"
                class={[
                  "mt-1 block text-right text-[10px] leading-none",
                  if(mine?(m, @current_user.id), do: "text-white/70", else: "text-slate-600 dark:text-slate-400")
                ]}
              />
            </div>
            <%!-- The quiet per-message report flag, beside the other side's
            bubbles. Faint until the row is hovered or the flag is focused, so
            it never crowds the conversation; always tappable on touch. --%>
            <.link
              :if={not mine?(m, @current_user.id)}
              id={"#{dom_id}-report"}
              navigate={~p"/reports/new?#{[type: "message", id: m.id, return_to: "/messages/#{m.conversation_id}"]}"}
              title={gettext("Report this message")}
              aria-label={gettext("Report this message")}
              class="text-xs text-slate-300 opacity-60 transition group-hover:opacity-100 hover:text-red-600 focus:opacity-100 dark:text-slate-600 dark:hover:text-red-400"
            >
              ⚑
            </.link>
          </div>
        </div>

        <%!-- WhatsApp-style typing bubble: animated dots while the other side writes --%>
        <div :if={typing_label(@typing_tokens)} id="typing-bubble" class="px-4 pb-2">
          <div class="inline-flex items-center gap-1 rounded-2xl bg-slate-100 px-4 py-3 dark:bg-slate-800">
            <span class="h-1.5 w-1.5 animate-bounce rounded-full bg-slate-400 [animation-delay:-0.3s]"></span>
            <span class="h-1.5 w-1.5 animate-bounce rounded-full bg-slate-400 [animation-delay:-0.15s]"></span>
            <span class="h-1.5 w-1.5 animate-bounce rounded-full bg-slate-400"></span>
          </div>
          <p class="mt-1 text-xs italic text-slate-600 dark:text-slate-400">{typing_label(@typing_tokens)}</p>
        </div>

        <div
          :if={Chat.request_recipient?(@conversation, @current_user.id)}
          id="request-banner"
          class="flex flex-wrap items-center justify-center gap-2 border-t border-slate-200 p-3 text-sm text-slate-600 dark:border-slate-800 dark:text-slate-300"
        >
          <span>{gettext("@%{slug} wants to message you.", slug: @other.username)}</span>
          <.request_actions id={@conversation.id} />
        </div>

        <.form
          :if={Chat.can_send?(@conversation, @current_user.id)}
          for={@form}
          id="message-form"
          phx-hook="ClearOnSubmit"
          phx-submit="send"
          phx-change="typing"
          class="flex gap-2 border-t border-slate-200 p-3 dark:border-slate-800"
        >
          <input
            type="text"
            name="message[body]"
            value={@form[:body].value}
            autocomplete="off"
            placeholder={gettext("Write a message…")}
            class="min-w-0 flex-1 rounded-full border border-slate-300 bg-white px-4 py-2 text-sm text-slate-800 focus:border-brand-500 focus:outline-none dark:border-slate-700 dark:bg-slate-800 dark:text-slate-100"
          />
          <button type="submit" class="rounded-full bg-brand-600 px-5 py-2 text-sm font-semibold text-white hover:bg-brand-700">
            {gettext("Send")}
          </button>
        </.form>

        <p
          :if={
            not Chat.can_send?(@conversation, @current_user.id) and
              not Chat.request_recipient?(@conversation, @current_user.id)
          }
          id="awaiting-acceptance"
          class="border-t border-slate-200 p-4 text-center text-sm text-slate-600 dark:text-slate-400 dark:border-slate-800"
        >
          {gettext("@%{slug} has not accepted your message request yet.", slug: @other.username)}
        </p>
      </section>

      <%!-- Desktop placeholder while no conversation is selected --%>
      <section
        :if={is_nil(@conversation)}
        class="hidden min-w-0 flex-1 items-center justify-center rounded-2xl bg-white ring-1 ring-slate-200 md:flex dark:bg-slate-900 dark:ring-slate-800"
      >
        <p class="text-sm text-slate-600 dark:text-slate-400">{gettext("Select a conversation.")}</p>
      </section>
    </div>
    """
  end
end
