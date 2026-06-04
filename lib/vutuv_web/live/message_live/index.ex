defmodule VutuvWeb.MessageLive.Index do
  @moduledoc """
  Messages page. Dummy conversations and seeded history for now, but the live
  plumbing is real: messages sent in one session appear instantly in every other
  session on the same conversation (PubSub), online status and typing indicators
  use `Phoenix.Presence`, and opening the page clears the unread message badge in
  the shell. Requires login; conversation ids are validated against the dummy
  list so nobody can subscribe to arbitrary topics. Messages are a LiveView
  stream, so long sessions don't accumulate them in process memory.
  Persistence comes later.
  """
  use VutuvWeb, :live_view

  alias Vutuv.Activity
  alias VutuvWeb.Presence

  @presence_topic "messages:online"
  @typing_clear_ms 2500

  @impl true
  def mount(params, _session, socket) do
    case socket.assigns[:current_user] do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Please log in to read your messages."))
         |> redirect(to: ~p"/sessions/new")}

      user ->
        conv_id = valid_conv_id(params["id"])
        user_name = display_name(user)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Vutuv.PubSub, convo_topic(conv_id))
          Phoenix.PubSub.subscribe(Vutuv.PubSub, @presence_topic)
          Presence.track(self(), @presence_topic, to_string(user.id), %{name: user_name})
          Activity.mark_messages_read(user.id)
        end

        {:ok,
         socket
         |> assign(:page_title, gettext("Messages"))
         |> assign(:current_user_id, user.id)
         |> assign(:user_name, user_name)
         |> assign(:conversations, conversations())
         |> assign(:conv_id, conv_id)
         |> assign(:typing_tokens, %{})
         |> assign(:online, list_online())
         |> stream(:messages, seed_messages(conv_id), dom_id: &"message-#{&1.id}")
         |> assign_form()}
    end
  end

  @impl true
  def handle_event("send", %{"message" => %{"body" => body}}, socket) do
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      msg = %{
        # Globally unique so two senders can't collide on stream DOM ids. The
        # "live-" prefix keeps it out of the seed id namespace: the counter
        # starts at 1 on a fresh node, and a bare integer id would collide with
        # a seeded message and replace it in the stream instead of appending.
        id: "live-#{System.unique_integer([:positive, :monotonic])}",
        from_id: socket.assigns.current_user_id,
        from_name: socket.assigns.user_name,
        body: body,
        at: DateTime.utc_now()
      }

      # Plain broadcast: every subscriber — including the sender — appends the
      # message via handle_info, so all sessions render the same thing.
      Phoenix.PubSub.broadcast(
        Vutuv.PubSub,
        convo_topic(socket.assigns.conv_id),
        {:new_message, msg}
      )

      {:noreply, assign_form(socket)}
    end
  end

  def handle_event("typing", _params, socket) do
    Phoenix.PubSub.broadcast_from(
      Vutuv.PubSub,
      self(),
      convo_topic(socket.assigns.conv_id),
      {:typing, socket.assigns.user_name}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:new_message, msg}, socket) do
    {:noreply, stream_insert(socket, :messages, msg)}
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
    {:noreply, assign(socket, :online, list_online())}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  ## helpers

  defp convo_topic(conv_id), do: "conversation:#{conv_id}"

  defp assign_form(socket), do: assign(socket, :form, to_form(%{"body" => ""}, as: :message))

  # One entry per presence key (= per user), not de-duplicated by display name,
  # so the online count is correct even when names repeat.
  defp list_online do
    @presence_topic
    |> Presence.list()
    |> Enum.map(fn {_key, %{metas: [meta | _]}} -> meta.name end)
  end

  defp display_name(user) do
    case VutuvWeb.UserHelpers.full_name(user) do
      "" -> gettext("Member")
      name -> name
    end
  end

  defp valid_conv_id(id) do
    if Enum.any?(conversations(), &(&1.id == id)), do: id, else: "1"
  end

  defp conversations do
    [
      %{id: "1", name: "José Daniel", last: "Loved your Phoenix talk.", online: true},
      %{id: "2", name: "Chris McCord", last: "Let's pair on LiveView.", online: true},
      %{id: "3", name: "Wojtek Mach", last: "Req 1.0 is out!", online: false}
    ]
  end

  defp seed_messages("1"),
    do: [
      %{
        id: 1,
        from_id: 999,
        from_name: "José Daniel",
        body: "Hey! Loved your Phoenix talk. 👏",
        at: DateTime.add(DateTime.utc_now(), -7200, :second)
      }
    ]

  defp seed_messages("2"),
    do: [
      %{
        id: 1,
        from_id: 998,
        from_name: "Chris McCord",
        body: "Want to pair on a LiveView this week?",
        at: DateTime.add(DateTime.utc_now(), -10_800, :second)
      }
    ]

  defp seed_messages(_), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <div id="messages" class="flex h-[calc(100vh-9rem)] gap-4 py-6 md:h-[calc(100vh-7rem)]">
      <%!-- Conversation list (hidden on small screens) --%>
      <aside class="hidden w-64 shrink-0 overflow-y-auto rounded-2xl bg-white ring-1 ring-slate-200 md:block dark:bg-slate-900 dark:ring-slate-800">
        <ul>
          <li :for={c <- @conversations}>
            <.link
              href={~p"/messages/#{c.id}"}
              class={[
                "flex items-center gap-3 px-4 py-3 hover:bg-slate-50 dark:hover:bg-slate-800",
                c.id == @conv_id && "bg-brand-50 dark:bg-brand-900/30"
              ]}
            >
              <span class="relative flex h-10 w-10 items-center justify-center rounded-full bg-brand-700 text-sm font-bold text-white">
                {String.first(c.name)}
                <span :if={c.online} class="absolute -bottom-0.5 -right-0.5 h-3 w-3 rounded-full bg-emerald-500 ring-2 ring-white dark:ring-slate-900" />
              </span>
              <span class="min-w-0">
                <span class="block truncate text-sm font-medium text-slate-800 dark:text-slate-100">{c.name}</span>
                <span class="block truncate text-xs text-slate-400">{c.last}</span>
              </span>
            </.link>
          </li>
        </ul>
      </aside>

      <%!-- Active thread --%>
      <section class="flex min-w-0 flex-1 flex-col rounded-2xl bg-white ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800">
        <header class="flex items-center justify-between border-b border-slate-200 px-4 py-3 dark:border-slate-800">
          <h1 class="font-semibold text-slate-800 dark:text-slate-100">{active_name(@conversations, @conv_id)}</h1>
          <%= if typing_label(@typing_tokens) do %>
            <span class="text-xs font-medium text-brand-600 dark:text-brand-400">{typing_label(@typing_tokens)}</span>
          <% else %>
            <span class="text-xs text-slate-400">{online_label(@online)}</span>
          <% end %>
        </header>

        <div id="message-thread" phx-update="stream" phx-hook="ScrollBottom" class="flex-1 space-y-2 overflow-y-auto p-4">
          <div
            :for={{dom_id, m} <- @streams.messages}
            id={dom_id}
            class={["flex", mine?(m, @current_user_id) && "justify-end"]}
          >
            <div class={[
              "max-w-[75%] break-words rounded-2xl px-3 py-2 text-sm",
              "[&_a]:underline [&_a]:break-all [&_blockquote]:border-l-2 [&_blockquote]:pl-2",
              "[&_code]:rounded [&_code]:px-1 [&_code]:font-mono [&_code]:text-[0.85em]",
              "[&_ol]:list-decimal [&_ol]:pl-4 [&_p+p]:mt-1 [&_ul]:list-disc [&_ul]:pl-4",
              if(mine?(m, @current_user_id),
                do: "bg-brand-600 text-white [&_a]:text-white [&_code]:bg-white/20",
                else:
                  "bg-slate-100 text-slate-800 dark:bg-slate-800 dark:text-slate-100 [&_a]:text-brand-700 dark:[&_a]:text-brand-300 [&_code]:bg-black/10 dark:[&_code]:bg-white/10"
              )
            ]}>
              <span :if={not mine?(m, @current_user_id)} class="mb-0.5 block text-xs font-semibold text-brand-700 dark:text-brand-300">{m.from_name}</span>
              {VutuvWeb.Markdown.render(m.body)}
              <time
                :if={m[:at]}
                id={"#{dom_id}-at"}
                phx-hook="LocalTime"
                datetime={DateTime.to_iso8601(m.at)}
                title={DateTime.to_iso8601(m.at)}
                class={[
                  "mt-1 block text-right text-[10px] leading-none",
                  if(mine?(m, @current_user_id), do: "text-white/70", else: "text-slate-400")
                ]}
              >{Calendar.strftime(m.at, "%d.%m.%Y %H:%M")}</time>
            </div>
          </div>
        </div>

        <%!-- WhatsApp-style typing bubble: animated dots while the other side writes --%>
        <div :if={typing_label(@typing_tokens)} id="typing-bubble" class="px-4 pb-2">
          <div class="inline-flex items-center gap-1 rounded-2xl bg-slate-100 px-4 py-3 dark:bg-slate-800">
            <span class="h-1.5 w-1.5 animate-bounce rounded-full bg-slate-400 [animation-delay:-0.3s]"></span>
            <span class="h-1.5 w-1.5 animate-bounce rounded-full bg-slate-400 [animation-delay:-0.15s]"></span>
            <span class="h-1.5 w-1.5 animate-bounce rounded-full bg-slate-400"></span>
          </div>
          <p class="mt-1 text-xs italic text-slate-400">{typing_label(@typing_tokens)}</p>
        </div>

        <.form for={@form} id="message-form" phx-hook="ClearOnSubmit" phx-submit="send" phx-change="typing" class="flex gap-2 border-t border-slate-200 p-3 dark:border-slate-800">
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
      </section>
    </div>
    """
  end

  defp mine?(%{from_id: from_id}, user_id), do: not is_nil(user_id) and from_id == user_id

  defp active_name(conversations, conv_id) do
    case Enum.find(conversations, &(&1.id == conv_id)) do
      nil -> "Conversation"
      c -> c.name
    end
  end

  defp online_label([]), do: ""
  defp online_label(names), do: "#{compact_count(length(names))} online"

  defp typing_label(typing_tokens) do
    case Map.keys(typing_tokens) do
      [] -> nil
      [name] -> "#{name} is typing…"
      names -> "#{Enum.join(names, ", ")} are typing…"
    end
  end
end
