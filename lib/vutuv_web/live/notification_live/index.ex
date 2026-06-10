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

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if connected?(socket) && user do
      Activity.subscribe(user.id)
      Activity.mark_notifications_read(user.id)
    end

    page =
      if user,
        do: Activity.notifications_page(user.id, limit: @page_size),
        else: %{entries: [], more?: false, next_cursor: nil}

    # What the "Load more" label counts down: feed events not on screen yet.
    # Live-pushed events show up immediately, so they never touch this number.
    total = if user, do: Activity.notifications_count(user.id), else: 0

    {:ok,
     socket
     |> assign(:page_title, gettext("Notifications"))
     |> assign(:empty?, Enum.empty?(page.entries))
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> assign(:remaining, max(total - length(page.entries), 0))
     |> stream(:notifications, page.entries, dom_id: &"notification-#{&1.id}")}
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    page =
      Activity.notifications_page(socket.assigns.current_user.id,
        limit: @page_size,
        cursor: socket.assigns.cursor
      )

    {:noreply,
     socket
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> assign(:remaining, max(socket.assigns.remaining - length(page.entries), 0))
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

    # The user is watching the event arrive, so it is already read: advance the
    # read marker, which broadcasts :notifications_read and keeps the shell's
    # bell badge at zero instead of bumping it for an event shown live here.
    if user = socket.assigns[:current_user], do: Activity.mark_notifications_read(user.id)

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
            <.link href={~p"/#{n.actor_param}"} class="mt-0.5 shrink-0">
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
                <.link href={~p"/#{n.actor_param}"} class="font-semibold text-slate-900 hover:text-brand-700 dark:text-white">
                  {n.actor_name}
                </.link>
              <% else %>
                <span :if={n[:actor_name]} class="font-semibold">{n.actor_name}</span>
              <% end %>
              <%!-- The event text leads to the thing it reports: the liked or
              replied-to post, the connections page for a request, the actor's
              profile otherwise. --%>
              <%= if target = notification_target(n, @current_user) do %>
                <.link href={target} class="hover:text-brand-700 hover:underline">
                  {notification_text(n)}
                </.link>
              <% else %>
                {notification_text(n)}
              <% end %>
            </p>
            <span class="text-xs uppercase tracking-wide text-slate-400">
              {kind_label(n.kind)}<span :if={n[:at]}> &middot; <time>{format_at(n.at)}</time></span>
            </span>
          </div>
        </li>
      </ul>

      <p :if={@empty?} class="mt-6 text-slate-400">{gettext("Nothing new yet.")}</p>

      <.load_more :if={@more?} class="mt-6">{load_more_label(@remaining)}</.load_more>
    </div>
    """
  end

  # "Load 50 of 80 more": the next batch size, then everything still unloaded,
  # so the user can tell how far into the feed they are. Counts render in the
  # site-wide compact form (exact up to 999, then 1K/5M).
  #
  # `remaining` is a mount-time snapshot of the feed size, while more?/cursor
  # follow the live database, so the snapshot can run dry (<= 0) while older
  # pages still exist. Showing "Load 0 of 0 more" would be nonsense, so fall
  # back to a plain label once the snapshot can no longer count down.
  defp load_more_label(remaining) when remaining <= 0, do: gettext("Load more")

  defp load_more_label(remaining) do
    gettext("Load %{count} of %{remaining} more",
      count: compact_count(min(@page_size, remaining)),
      remaining: compact_count(remaining)
    )
  end

  # The connection family — request, accept and the legacy mutual event — all
  # share one badge colour and glyph.
  @connection_kinds ~w(connection connection_request connection_accepted)

  defp kind_classes("follower"),
    do: "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"

  defp kind_classes("endorsement"), do: "bg-emerald-50 text-emerald-600 dark:bg-emerald-900/30"

  defp kind_classes("reply"),
    do: "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"

  defp kind_classes("like"), do: "bg-accent/10 text-accent dark:bg-accent/20"

  defp kind_classes(kind) when kind in @connection_kinds,
    do: "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"

  defp kind_classes("moderation"),
    do: "bg-amber-50 text-amber-600 dark:bg-amber-900/30 dark:text-amber-200"

  defp kind_classes(_), do: "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-300"

  defp kind_glyph("follower"), do: "+"
  defp kind_glyph("endorsement"), do: "★"
  defp kind_glyph("reply"), do: "↩"
  defp kind_glyph("like"), do: "♥"
  defp kind_glyph(kind) when kind in @connection_kinds, do: "🤝"
  defp kind_glyph("moderation"), do: "⚑"
  defp kind_glyph(_), do: "•"

  # The small uppercase tag under the event text. Translated like the text
  # itself; raw kind strings ("connection_request") must not leak to users.
  defp kind_label("follower"), do: gettext("Follower")
  defp kind_label("endorsement"), do: gettext("Endorsement")
  defp kind_label("reply"), do: gettext("Reply")
  defp kind_label("like"), do: gettext("Like")
  defp kind_label("connection"), do: gettext("Connection")
  defp kind_label("connection_request"), do: gettext("Connection request")
  defp kind_label("connection_accepted"), do: gettext("Connection")
  defp kind_label("moderation"), do: gettext("Moderation")
  defp kind_label(_), do: gettext("Activity")

  # Where clicking the event text leads. Events about one of the viewer's
  # posts open that post's thread; a pending request opens the page where it
  # can be answered; an endorsement the viewer's tags; everything else the
  # actor's profile. Logged-out renders (no viewer) only ever get the latter.
  # Moderation events lead to the owner's case page (and carry no actor).
  defp notification_target(%{kind: "moderation"} = n, viewer) do
    if is_binary(n[:case_id]) and viewer != nil, do: ~p"/moderation/cases/#{n.case_id}"
  end

  defp notification_target(n, viewer) do
    cond do
      n.kind in ["reply", "like"] and is_binary(n[:post_id]) and viewer ->
        ~p"/#{viewer}/posts/#{n.post_id}"

      n.kind == "connection_request" and viewer ->
        ~p"/#{viewer}/connections"

      n.kind == "endorsement" and viewer ->
        ~p"/#{viewer}/tags"

      is_binary(n[:actor_param]) ->
        ~p"/#{n.actor_param}"

      true ->
        nil
    end
  end

  # The event text is rendered from the kind (not stored), so it translates
  # with the viewer's locale. Unknown kinds fall back to the pushed text.
  defp notification_text(%{kind: "follower"}), do: gettext("started following you.")

  defp notification_text(%{kind: "endorsement", tag: tag}),
    do: gettext("endorsed you for %{tag}.", tag: tag)

  defp notification_text(%{kind: "connection"}), do: gettext("is now connected with you.")

  defp notification_text(%{kind: "connection_request"}),
    do: gettext("wants to connect with you.")

  defp notification_text(%{kind: "connection_accepted"}),
    do: gettext("accepted your connection request.")

  defp notification_text(%{kind: "reply"}), do: gettext("replied to your post.")
  defp notification_text(%{kind: "like"}), do: gettext("liked your post.")

  # Moderation items carry no actor (reports are anonymous); the text alone
  # tells the owner what happened and links to the case page.
  defp notification_text(%{kind: "moderation"} = n) do
    case n[:status] do
      "upheld" -> gettext("A report about your content was confirmed.")
      "rejected" -> gettext("A report about your content was dismissed; it is visible again.")
      "resolved_edited" -> gettext("You revised reported content; the case is closed.")
      "resolved_deleted" -> gettext("You deleted reported content; the case is closed.")
      _ -> gettext("Your content was reported and is hidden while the report is handled.")
    end
  end

  defp notification_text(n), do: n[:text]

  defp format_at(%mod{} = at) when mod in [NaiveDateTime, DateTime],
    do: Calendar.strftime(at, "%Y-%m-%d")

  defp format_at(_), do: nil
end
