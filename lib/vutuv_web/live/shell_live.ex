defmodule VutuvWeb.ShellLive do
  @moduledoc """
  The app shell — the sticky top bar plus the mobile bottom tab bar. Rendered
  once and embedded in the `app` layout via `live_render` (sticky), so it
  persists across live navigation and carries the live unread badges (messages,
  notifications) that update in real time from `Vutuv.Activity` (PubSub on
  `"user:<id>"`).

  Uses `Phoenix.LiveView` directly (no `app` layout) to avoid wrapping itself.
  Both badges are real unread counts: notifications via
  `Vutuv.Activity.unread_notification_count/1` (events newer than the user's
  read marker), messages via `Vutuv.Chat.unread_conversations_count/1`
  (conversations holding unread messages).
  """
  use Phoenix.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.UI, only: [count_badge: 1, icon_bookmark: 1, name_initials: 1, presence_dot: 1]

  alias Vutuv.Activity
  alias Vutuv.Social
  alias VutuvWeb.Presence

  @impl true
  def mount(_params, session, socket) do
    # LayoutHTML.shell_session/1 (the curated :session) only carries the
    # profile fields (user_param/name/avatar) for a current, valid user.
    # Phoenix.LiveView.Static merges the raw browser session UNDER it, so a
    # cookie pointing at a since-deleted or UUID-re-keyed account (every
    # pre-cutover session is now one) leaks its bare `user_id` here with no
    # profile fields. Key "logged in" off `user_param`, which only
    # shell_session sets, so such a session renders the anonymous shell instead
    # of the logged-in chrome that would crash on `~p"/#{nil}"`. cast_or_nil
    # also tolerates the integer ids in cookies from before the UUID cutover.
    user_param = session["user_param"]
    user_id = user_param && Vutuv.UUIDv7.cast_or_nil(session["user_id"])
    if connected?(socket), do: Activity.subscribe(user_id)

    # The shell mounts outside the `live_session` (embedded via live_render),
    # so InitAssigns never runs for it — apply the session locale here.
    VutuvWeb.LiveLocale.put_locale(session)

    # When the shell mounts ON the messages/notifications page itself, that
    # badge starts at zero. Relying only on the page's read-broadcast races the
    # shell's subscribe on full page loads (the broadcast can fire first).
    path = session["path"] || ""

    socket =
      socket
      |> assign(:user_id, user_id)
      |> assign(:user_name, session["user_name"])
      # Initials are built from first+last (matching <.avatar>); fall back to the
      # display name only for sessions built before that key existed.
      |> assign(:user_initials, session["user_initials"] || name_initials(session["user_name"]))
      |> assign(:user_param, user_param)
      |> assign(:user_avatar, session["user_avatar"])
      |> assign(:user_admin?, session["user_admin?"] == true)
      |> assign(:self_online?, false)
      |> assign(:presence_hidden_ids, MapSet.new())
      # The badge counts are the most expensive query on every page (an 8-way
      # aggregate for notifications, a COUNT(DISTINCT) join for messages). The
      # dead (static HTTP) render is thrown away the instant the socket connects,
      # so computing them there doubles that cost site-wide for no benefit:
      # start at 0 (count_badge renders nothing at 0) and fill them in on
      # connect. A real unread count appears within a fraction of a second.
      |> assign(:messages_count, 0)
      |> assign(:notifications_count, 0)
      |> assign(:brand_path, brand_path(user_param, path))
      |> maybe_start_counts(user_id, path)
      |> maybe_start_presence(user_id, session["show_online"] == true)
      |> push_badge()

    {:ok, socket}
  end

  # Site-wide online presence. The shell is the one component on every page, so
  # it is where the current member is tracked online. Tracking (broadcasting my
  # own dot) is gated by the member's "Show when I'm online" setting; seeing
  # other members' dots is not — every logged-in viewer subscribes and receives
  # the online set, minus anyone a block hides from them (either direction).
  # Compute the unread badges only on the connected mount (never the dead
  # render) and only for a logged-in member. When the shell mounts ON the
  # messages/notifications page itself that badge starts at zero (initial_count),
  # since the page's own read-broadcast can race the shell's subscribe.
  defp maybe_start_counts(socket, nil, _path), do: socket

  defp maybe_start_counts(socket, user_id, path) do
    if connected?(socket) do
      socket
      |> assign(
        :messages_count,
        initial_count(path, "/messages", user_id, &Vutuv.Chat.unread_conversations_count/1)
      )
      |> assign(
        :notifications_count,
        initial_count(path, "/notifications", user_id, &Activity.unread_notification_count/1)
      )
    else
      socket
    end
  end

  defp maybe_start_presence(socket, nil, _show_online?), do: socket

  defp maybe_start_presence(socket, user_id, show_online?) do
    if connected?(socket) do
      if show_online?, do: Presence.track_user(self(), user_id)
      Presence.subscribe_online()

      socket
      |> assign(:self_online?, show_online?)
      |> assign(:presence_hidden_ids, Social.blocked_user_ids(user_id))
      |> push_online()
    else
      socket
    end
  end

  # The online set this viewer may see: everyone online, minus the members a
  # block hides from them. Includes the viewer themselves (when tracked), so
  # their own avatar shows the dot everywhere too. Pushed to the Presence JS
  # hook, which toggles the dot on every avatar in the page by user id.
  defp push_online(socket) do
    online =
      Presence.online_ids()
      |> MapSet.difference(socket.assigns.presence_hidden_ids)
      |> MapSet.to_list()

    push_event(socket, "presence:set", %{online: online})
  end

  defp initial_count(path, prefix, user_id, counter) do
    # Match the route boundary, not a raw prefix: a profile whose slug merely
    # begins with "messages"/"notifications" (e.g. /messagesanna) must not zero
    # the badge as if the member were sitting on that page.
    on_page? = path == prefix or String.starts_with?(path, prefix <> "/")
    if on_page?, do: 0, else: counter.(user_id)
  end

  # Where the logo goes. Normally "home" ("/", which routes a logged-in member
  # to their feed), but ON the feed itself that would be a no-op round trip, so
  # there it deep-links to the member's own profile instead.
  defp brand_path(user_param, "/feed") when is_binary(user_param), do: ~p"/#{user_param}"
  defp brand_path(_user_param, _path), do: ~p"/"

  # Both badges recompute from the source of truth rather than adjusting a
  # running tally, so they can't drift. A bare +1 on :new_notification went
  # stale the moment a counted event was *removed* with no notification to
  # announce it (a withdrawn or declined connection request), and only
  # self-healed on a full reload (issue #782). :notifications_changed is that
  # silent-decrement signal (broadcast by Vutuv.Social), and recomputing on
  # :new_notification too keeps the increment honest.
  @impl true
  def handle_info({:new_notification, _n}, socket),
    do: {:noreply, recount_notifications(socket)}

  def handle_info(:notifications_changed, socket),
    do: {:noreply, recount_notifications(socket)}

  def handle_info(:notifications_read, socket),
    do: {:noreply, socket |> assign(:notifications_count, 0) |> push_badge()}

  # Vutuv.Chat broadcasts :new_message on every delivered message and
  # MessageLive's mark_read broadcasts :messages_read when the member opens a
  # conversation. The badge counts unread *conversations*, which neither event
  # maps to additively — a repeat message in an already-unread conversation
  # adds nothing, and reading one conversation says nothing about the others —
  # so both recompute the count instead of adjusting it.
  def handle_info({:new_message, _m}, socket),
    do: {:noreply, recount_messages(socket)}

  def handle_info(:messages_read, socket),
    do: {:noreply, recount_messages(socket)}

  # A new post reached this member's feed (Vutuv.Posts.create_post broadcasts
  # {:new_post, …} to the author *and* every follower). They may be reading
  # another page or another tab, so nudge the TabBadge hook to mark the browser
  # tab. Skip a post the member wrote themselves — their own post must not badge
  # their own tab. The hook only shows the "new posts" dot while the tab is
  # backgrounded and clears it the moment they return, so feed posts (which have
  # no read state) need no server-side unread tally.
  def handle_info({:new_post, %{author_id: author_id}}, socket) do
    socket =
      if author_id == socket.assigns.user_id,
        do: socket,
        else: push_event(socket, "tab:new_post", %{})

    {:noreply, socket}
  end

  # A member joined or left site-wide presence: re-push this viewer's (block-
  # filtered) online set so the JS hook updates every avatar's dot live.
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, push_online(socket)}

  # The member flipped "Show when I'm online" (here or in another tab): start or
  # stop broadcasting their own dot live, no reload needed.
  def handle_info({:presence_pref, show_online?}, socket) do
    if show_online?,
      do: Presence.track_user(self(), socket.assigns.user_id),
      else: Presence.untrack_user(self(), socket.assigns.user_id)

    {:noreply, socket |> assign(:self_online?, show_online?) |> push_online()}
  end

  # A block changed for this member (either direction): refresh their block
  # filter so a newly blocked member's dot disappears (and an unblocked one's
  # can reappear) without waiting for the next full page load.
  def handle_info(:presence_blocks_changed, socket) do
    {:noreply,
     socket
     |> assign(:presence_hidden_ids, Social.blocked_user_ids(socket.assigns.user_id))
     |> push_online()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp recount_messages(socket) do
    socket
    |> assign(:messages_count, Vutuv.Chat.unread_conversations_count(socket.assigns.user_id))
    |> push_badge()
  end

  defp recount_notifications(socket) do
    socket
    |> assign(:notifications_count, Activity.unread_notification_count(socket.assigns.user_id))
    |> push_badge()
  end

  # Push the current attention total (unread messages + notifications) to the
  # TabBadge JS hook, which prefixes the browser-tab <title> with "(N)" so a
  # backgrounded tab shows there is something to read. Sent on connect and
  # whenever either count changes; no-op for a logged-out shell (no hook) and on
  # the throwaway dead render.
  defp push_badge(%{assigns: %{user_id: nil}} = socket), do: socket

  defp push_badge(socket) do
    if connected?(socket) do
      unread = socket.assigns.messages_count + socket.assigns.notifications_count
      push_event(socket, "tab:badge", %{unread: unread})
    else
      socket
    end
  end

  # The initials tile shares VutuvWeb.UI.name_initials/1 with <.avatar>.

  @impl true
  def render(assigns) do
    ~H"""
    <div id="app-shell">
      <%!-- Drives the green "online" dot on every avatar in the page. Receives
      this viewer's online-id set from ShellLive (push_event "presence:set") and
      writes a generated stylesheet that reveals each online member's
      [data-presence-user-id] dot, across classic controller pages too. Empty +
      phx-update="ignore": it manages a document-wide stylesheet, not children. --%>
      <div :if={@user_id} id="presence-hook" phx-hook="Presence" phx-update="ignore" class="hidden"></div>
      <%!-- Drives the browser-tab title indicator: prefixes document.title with
      "(N)" for unread messages + notifications and a "•" for new feed posts that
      arrived while the tab was backgrounded (see the TabBadge hook in app.js).
      Fed by push_badge/1 + the {:new_post} handler; phx-update="ignore" because
      the hook owns document.title, not this node. --%>
      <div :if={@user_id} id="tab-badge" phx-hook="TabBadge" phx-update="ignore" class="hidden"></div>
      <header class="sticky top-0 z-30 border-b border-slate-200 bg-white/90 backdrop-blur dark:border-slate-800 dark:bg-slate-900/90">
        <div class="mx-auto flex h-16 max-w-6xl items-center gap-6 px-4">
          <%!-- The logo is "home": for a logged-in member "/" redirects to their
               home (feed or profile) via RequireUserLoggedOut; logged out it is the
               landing page. On /feed itself it links to the member's own profile
               instead (see brand_path/2). --%>
          <.link
            href={@brand_path}
            data-brand
            class="shrink-0 text-2xl font-extrabold tracking-tight text-brand-800 dark:text-white"
          >
            vutuv
          </.link>

          <nav aria-label={gettext("Main navigation")} class="hidden items-center gap-1 text-sm font-medium md:flex">
            <.link
              :if={@user_id}
              href={~p"/feed"}
              class="rounded-md px-3 py-2 text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"
            >
              {gettext("Feed")}
            </.link>
            <.link
              href={~p"/listings/most_followed_users"}
              class="rounded-md px-3 py-2 text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"
            >
              {gettext("Network")}
            </.link>
            <.link
              href={~p"/jobs"}
              class="rounded-md px-3 py-2 text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"
            >
              {gettext("Jobs")}
            </.link>
          </nav>

          <div class="ml-auto flex items-center gap-1">
            <.link
              href={~p"/search"}
              title={gettext("Search")}
              class="hidden h-10 w-10 items-center justify-center rounded-full text-slate-500 hover:bg-slate-100 sm:flex dark:text-slate-400 dark:hover:bg-slate-800"
            >
              <.icon_search />
            </.link>

            <%= if @user_id do %>
              <.link
                href={~p"/bookmarks"}
                title={gettext("Bookmarks")}
                class="hidden h-10 w-10 items-center justify-center rounded-full text-slate-500 hover:bg-slate-100 md:flex dark:text-slate-400 dark:hover:bg-slate-800"
              >
                <.icon_bookmark class="h-6 w-6" />
              </.link>
              <.link
                href={~p"/messages"}
                title={gettext("Messages")}
                class="relative hidden h-10 w-10 items-center justify-center rounded-full text-slate-500 hover:bg-slate-100 md:flex dark:text-slate-400 dark:hover:bg-slate-800"
              >
                <.icon_envelope />
                <.count_badge
                  count={@messages_count}
                  class="absolute -right-0.5 -top-0.5 ring-2 ring-white dark:ring-slate-900"
                />
              </.link>
              <.link
                href={~p"/notifications"}
                title={gettext("Notifications")}
                class="relative hidden h-10 w-10 items-center justify-center rounded-full text-slate-500 hover:bg-slate-100 md:flex dark:text-slate-400 dark:hover:bg-slate-800"
              >
                <.icon_bell />
                <.count_badge
                  count={@notifications_count}
                  class="absolute -right-0.5 -top-0.5 ring-2 ring-white dark:ring-slate-900"
                />
              </.link>
              <%!-- The avatar opens the account menu (a native <details data-menu>,
              light-dismissed by app.js): the single, conventional home for every
              account/settings destination, so the whole surface is one click from
              anywhere. Log out lives here now instead of as its own bar icon. --%>
              <details data-menu data-account-menu class="relative ml-1 shrink-0" id="account-menu">
                <summary
                  title={@user_name}
                  class="flex cursor-pointer list-none items-center rounded-full focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 [&::-webkit-details-marker]:hidden"
                >
                  <%!-- Your own avatar carries the online dot too (server-driven
                  by @self_online?, since the shell owns this DOM — no JS hook). --%>
                  <span class="relative inline-flex">
                    <%= if @user_avatar do %>
                      <img src={@user_avatar} alt={@user_name} class="h-9 w-9 rounded-full object-cover" />
                    <% else %>
                      <span class="flex h-9 w-9 items-center justify-center rounded-full bg-brand-700 text-sm font-bold text-white">
                        {@user_initials}
                      </span>
                    <% end %>
                    <.presence_dot online={@self_online?} size="sm" />
                  </span>
                  <span class="sr-only">{gettext("Account menu")}</span>
                </summary>

                <div class="absolute right-0 z-20 mt-2 w-60 rounded-xl bg-white py-1 shadow-lg ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-700">
                  <.link
                    href={~p"/#{@user_param}"}
                    data-self-profile
                    class="block border-b border-slate-100 px-4 py-3 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-800"
                  >
                    <span class="block truncate text-sm font-semibold text-slate-900 dark:text-slate-100">
                      {@user_name}
                    </span>
                    <span class="block text-xs text-slate-600 dark:text-slate-400">
                      {gettext("View profile")}
                    </span>
                  </.link>

                  <.link href={~p"/bookmarks"} class={[menu_item_class(), "block"]}>
                    {gettext("Bookmarks")}
                  </.link>
                  <.link href={~p"/likes"} class={[menu_item_class(), "block"]}>
                    {gettext("Likes")}
                  </.link>

                  <%!-- The member's "Your organizations" hub: the pages they own
                  or help run, plus the explainer and the add call to action. The
                  public browse directory stays linked in the footer. --%>
                  <.link href={~p"/settings/organizations"} class={[menu_item_class(), "block"]}>
                    {gettext("Organizations")}
                  </.link>

                  <.link href={~p"/system/invitations/new"} class={[menu_item_class(), "block"]}>
                    {gettext("Invite a friend")}
                  </.link>

                  <div class="my-1 border-t border-slate-100 dark:border-slate-800"></div>

                  <%!-- "Settings" opens the settings hub — the one grouped map of
                  everything editable — so the label finally matches the
                  destination (it used to alias the profile-basics form). --%>
                  <.link href={~p"/settings"} class={[menu_item_class(), "block"]}>
                    {gettext("Settings")}
                  </.link>

                  <%!-- Only admins see this; the link is the single entry point
                  into the /admin control panel (there is no other nav to it). --%>
                  <.link
                    :if={@user_admin?}
                    href={~p"/admin"}
                    class={[menu_item_class(), "block font-semibold text-brand-700 dark:text-brand-400"]}
                  >
                    {gettext("Admin")}
                  </.link>

                  <%!-- Power-user affordance: opens the shortcuts overlay (wired in
                  app.js). Hidden on touch devices, where shortcuts don't apply. --%>
                  <button
                    type="button"
                    data-shortcuts-trigger
                    class={[menu_item_class(), "flex w-full items-center justify-between [@media(hover:none)]:hidden"]}
                  >
                    {gettext("Keyboard shortcuts")}
                    <kbd class="rounded border border-slate-300 px-1.5 text-xs font-normal text-slate-500 dark:border-slate-600 dark:text-slate-400">
                      ?
                    </kbd>
                  </button>

                  <div class="my-1 border-t border-slate-100 dark:border-slate-800"></div>

                  <.link href={~p"/logout"} method="delete" class={[menu_item_class(), "block"]}>
                    {gettext("Log out")}
                  </.link>
                </div>
              </details>
            <% else %>
              <.link
                href={~p"/login"}
                class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
              >
                {gettext("Log in")}
              </.link>
            <% end %>
          </div>
        </div>
      </header>

      <%!-- Mobile bottom tab bar (fixed; content in the layout reserves space) --%>
      <%!-- Logged out, Messages/Alerts would only bounce the visitor to the
      login page, so the anonymous bar offers Log in directly instead. --%>
      <nav
        aria-label={gettext("Main navigation")}
        class={[
          "fixed inset-x-0 bottom-0 z-30 grid h-16 border-t border-slate-200 bg-white/95 backdrop-blur md:hidden dark:border-slate-800 dark:bg-slate-900/95",
          if(@user_id, do: "grid-cols-4", else: "grid-cols-2")
        ]}
      >
        <%= if @user_id do %>
          <.tab href={~p"/feed"} label={gettext("Feed")}><.icon_feed /></.tab>
        <% end %>
        <.tab href={~p"/search"} label={gettext("Search")}><.icon_search /></.tab>
        <%= if @user_id do %>
          <.tab href={~p"/messages"} label={gettext("Messages")} count={@messages_count}><.icon_envelope /></.tab>
          <.tab href={~p"/notifications"} label={gettext("Alerts")} count={@notifications_count}><.icon_bell /></.tab>
        <% else %>
          <.tab href={~p"/login"} label={gettext("Log in")}><.icon_login /></.tab>
        <% end %>
      </nav>
    </div>
    """
  end

  ## Components

  attr(:href, :string, required: true)
  attr(:label, :string, required: true)
  attr(:count, :integer, default: 0)
  slot(:inner_block, required: true)

  defp tab(assigns) do
    ~H"""
    <.link href={@href} class="flex flex-col items-center justify-center gap-0.5 text-slate-600 dark:text-slate-400">
      <span class="relative">
        {render_slot(@inner_block)}
        <.count_badge
          count={@count}
          class="absolute -right-0.5 -top-0.5 ring-2 ring-white dark:ring-slate-900"
        />
      </span>
      <span class="text-[10px]">{@label}</span>
    </.link>
    """
  end

  # Shared classes for an avatar account-menu item — mirrors the card_menu
  # item styling so both dropdowns read the same. The display utility
  # (block / flex) is added per call site.
  defp menu_item_class do
    "px-4 py-2 text-left text-sm font-medium text-slate-700 hover:bg-slate-50 dark:text-slate-200 dark:hover:bg-slate-800"
  end

  defp icon_search(assigns) do
    ~H"""
    <svg class="h-6 w-6" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" d="m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607Z" />
    </svg>
    """
  end

  defp icon_envelope(assigns) do
    ~H"""
    <svg class="h-6 w-6" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" d="M21.75 6.75v10.5a2.25 2.25 0 0 1-2.25 2.25h-15a2.25 2.25 0 0 1-2.25-2.25V6.75m19.5 0A2.25 2.25 0 0 0 19.5 4.5h-15a2.25 2.25 0 0 0-2.25 2.25m19.5 0v.243a2.25 2.25 0 0 1-1.07 1.916l-7.5 4.615a2.25 2.25 0 0 1-2.36 0L3.32 8.91a2.25 2.25 0 0 1-1.07-1.916V6.75" />
    </svg>
    """
  end

  defp icon_bell(assigns) do
    ~H"""
    <svg class="h-6 w-6" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" d="M14.857 17.082a23.848 23.848 0 0 0 5.454-1.31A8.967 8.967 0 0 1 18 9.75V9A6 6 0 0 0 6 9v.75a8.967 8.967 0 0 1-2.312 6.022c1.733.64 3.56 1.085 5.455 1.31m5.714 0a24.255 24.255 0 0 1-5.714 0m5.714 0a3 3 0 1 1-5.714 0" />
    </svg>
    """
  end

  defp icon_feed(assigns) do
    ~H"""
    <svg class="h-6 w-6" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M12 7.5h1.5m-1.5 3h1.5m-7.5 3h7.5m-7.5 3h7.5m3-9h3.375c.621 0 1.125.504 1.125 1.125V18a2.25 2.25 0 0 1-2.25 2.25M16.5 7.5V18a2.25 2.25 0 0 0 2.25 2.25M16.5 7.5V4.875c0-.621-.504-1.125-1.125-1.125H4.125C3.504 3.75 3 4.254 3 4.875V18a2.25 2.25 0 0 0 2.25 2.25h13.5M6 7.5h3v3H6v-3Z"
      />
    </svg>
    """
  end

  # The logout door, arrow pointing in.
  defp icon_login(assigns) do
    ~H"""
    <svg class="h-6 w-6" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" d="M8.25 9V5.25A2.25 2.25 0 0 1 10.5 3h6a2.25 2.25 0 0 1 2.25 2.25v13.5A2.25 2.25 0 0 1 16.5 21h-6a2.25 2.25 0 0 1-2.25-2.25V15m3-3H2.25m9 0-3-3m3 3-3 3" />
    </svg>
    """
  end
end
