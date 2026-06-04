defmodule VutuvWeb.NotificationLive.Index do
  @moduledoc """
  Notifications page. The feed is real data derived at mount time by
  `Vutuv.Activity.notifications_page/2` from the event tables that already
  exist (followers, endorsements, mutual connections), so it reaches back to
  events from before this page existed. Older pages load on demand via the
  "Load more" button (cursor pagination, appended to the stream). On top of
  that it updates live: new events arrive over `Vutuv.Activity` (PubSub
  `"user:<id>"`) and are prepended in real time. Visiting the page persists
  the read marker and clears the unread bell badge in the shell. Items are a
  LiveView stream, so a long-lived session doesn't accumulate them in process
  memory.
  """
  use VutuvWeb, :live_view

  alias Vutuv.Activity

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if connected?(socket) && user do
      Activity.subscribe(user.id)
      Activity.mark_notifications_read(user.id)
    end

    page =
      if user,
        do: Activity.notifications_page(user.id),
        else: %{entries: [], more?: false, next_cursor: nil}

    {:ok,
     socket
     |> assign(:page_title, gettext("Notifications"))
     |> assign(:empty?, Enum.empty?(page.entries))
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> stream(:notifications, page.entries, dom_id: &"notification-#{&1.id}")}
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    page =
      Activity.notifications_page(socket.assigns.current_user.id,
        cursor: socket.assigns.cursor
      )

    {:noreply,
     socket
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> stream(:notifications, page.entries, at: -1)}
  end

  @impl true
  def handle_info({:new_notification, notification}, socket) do
    item =
      notification
      |> Map.put_new(:kind, "activity")
      # Pushed events carry no row id, so mint one. The "live-" prefix keeps
      # them out of the derived "<kind>-<row id>" namespace - a pushed event
      # must prepend, never update a derived row in place.
      |> Map.put(:id, "live-#{System.unique_integer([:positive, :monotonic])}")

    {:noreply,
     socket
     |> assign(:empty?, false)
     |> stream_insert(:notifications, item, at: 0)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="notifications" class="py-8">
      <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">{gettext("Notifications")}</h1>

      <ul id="notification-list" phx-update="stream" class="mt-6 space-y-3">
        <li
          :for={{dom_id, n} <- @streams.notifications}
          id={dom_id}
          class="flex items-start gap-3 rounded-2xl bg-white px-4 py-3 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800"
        >
          <%!-- Show the actor's avatar (linked) when we have a picture; events
          whose payload carries no user struct (e.g. a bare-map broadcast) keep
          the colored kind glyph. --%>
          <%= if n[:actor_avatar] do %>
            <.link href={~p"/users/#{n.actor_param}"} class="mt-0.5 shrink-0">
              <.avatar src={n[:actor_avatar]} size="sm" alt={"Avatar of #{n.actor_name}"} />
            </.link>
          <% else %>
            <span class={[
              "mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-sm font-bold",
              kind_classes(n.kind)
            ]}>
              {kind_glyph(n.kind)}
            </span>
          <% end %>
          <div>
            <p class="text-slate-800 dark:text-slate-100">
              <%= if n[:actor_param] do %>
                <.link href={~p"/users/#{n.actor_param}"} class="font-semibold text-slate-900 hover:text-brand-700 dark:text-white">
                  {n.actor_name}
                </.link>
              <% else %>
                <span :if={n[:actor_name]} class="font-semibold">{n.actor_name}</span>
              <% end %>
              {notification_text(n)}
            </p>
            <span class="text-xs uppercase tracking-wide text-slate-400">
              {n.kind}<span :if={n[:at]}> &middot; <time>{format_at(n.at)}</time></span>
            </span>
          </div>
        </li>
      </ul>

      <p :if={@empty?} class="mt-6 text-slate-400">{gettext("Nothing new yet.")}</p>

      <div :if={@more?} class="mt-6 text-center">
        <.button id="load-more" variant="secondary" phx-click="load-more" phx-disable-with="…">
          {gettext("Load more")}
        </.button>
      </div>
    </div>
    """
  end

  defp kind_classes("follower"),
    do: "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"

  defp kind_classes("endorsement"), do: "bg-emerald-50 text-emerald-600 dark:bg-emerald-900/30"
  defp kind_classes(_), do: "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-300"

  defp kind_glyph("follower"), do: "+"
  defp kind_glyph("endorsement"), do: "★"
  defp kind_glyph(_), do: "•"

  # The event text is rendered from the kind (not stored), so it translates
  # with the viewer's locale. Unknown kinds fall back to the pushed text.
  defp notification_text(%{kind: "follower"}), do: gettext("started following you.")

  defp notification_text(%{kind: "endorsement", tag: tag}),
    do: gettext("endorsed you for %{tag}.", tag: tag)

  defp notification_text(%{kind: "connection"}), do: gettext("is now connected with you.")
  defp notification_text(n), do: n[:text]

  defp format_at(%mod{} = at) when mod in [NaiveDateTime, DateTime],
    do: Calendar.strftime(at, "%Y-%m-%d")

  defp format_at(_), do: nil
end
