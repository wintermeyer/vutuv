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

  import VutuvWeb.UI, only: [count_badge: 1, icon_bookmark: 1, name_initials: 1]

  alias Vutuv.Activity

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

    {:ok,
     socket
     |> assign(:user_id, user_id)
     |> assign(:user_name, session["user_name"])
     |> assign(:user_param, user_param)
     |> assign(:user_avatar, session["user_avatar"])
     |> assign(
       :messages_count,
       initial_count(path, "/messages", user_id, &Vutuv.Chat.unread_conversations_count/1)
     )
     |> assign(
       :notifications_count,
       initial_count(path, "/notifications", user_id, &Activity.unread_notification_count/1)
     )}
  end

  defp initial_count(path, prefix, user_id, counter) do
    if String.starts_with?(path, prefix), do: 0, else: counter.(user_id)
  end

  @impl true
  def handle_info({:new_notification, _n}, socket),
    do: {:noreply, update(socket, :notifications_count, &(&1 + 1))}

  # Vutuv.Chat broadcasts this to the recipient on every delivered message;
  # MessageLive's mark_read broadcasts :messages_read below to zero it again
  # while the member is looking at the conversation.
  def handle_info({:new_message, _m}, socket),
    do: {:noreply, update(socket, :messages_count, &(&1 + 1))}

  def handle_info(:notifications_read, socket),
    do: {:noreply, assign(socket, :notifications_count, 0)}

  def handle_info(:messages_read, socket),
    do: {:noreply, assign(socket, :messages_count, 0)}

  def handle_info(_other, socket), do: {:noreply, socket}

  # The initials tile shares VutuvWeb.UI.name_initials/1 with <.avatar>.

  @impl true
  def render(assigns) do
    ~H"""
    <div id="app-shell">
      <header class="sticky top-0 z-30 border-b border-slate-200 bg-white/90 backdrop-blur dark:border-slate-800 dark:bg-slate-900/90">
        <div class="mx-auto flex h-16 max-w-6xl items-center gap-6 px-4">
          <.link href={~p"/"} class="shrink-0 text-2xl font-extrabold tracking-tight text-brand-800 dark:text-white">
            vutuv
          </.link>

          <nav class="hidden items-center gap-1 text-sm font-medium md:flex">
            <.link href={~p"/"} class="rounded-md px-3 py-2 text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800">
              {gettext("Home")}
            </.link>
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
              <.link href={~p"/#{@user_param}"} title={@user_name} class="ml-1 shrink-0">
                <%= if @user_avatar do %>
                  <img src={@user_avatar} alt={@user_name} class="h-9 w-9 rounded-full object-cover" />
                <% else %>
                  <span class="flex h-9 w-9 items-center justify-center rounded-full bg-brand-700 text-sm font-bold text-white">
                    {name_initials(@user_name)}
                  </span>
                <% end %>
              </.link>
              <.link
                href={~p"/logout"}
                method="delete"
                title={gettext("Log out")}
                class="flex h-10 w-10 items-center justify-center rounded-full text-slate-400 hover:bg-slate-100 dark:hover:bg-slate-800"
              >
                <.icon_logout />
              </.link>
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
      <nav class={[
        "fixed inset-x-0 bottom-0 z-30 grid h-16 border-t border-slate-200 bg-white/95 backdrop-blur md:hidden dark:border-slate-800 dark:bg-slate-900/95",
        if(@user_id, do: "grid-cols-5", else: "grid-cols-3")
      ]}>
        <.tab href={~p"/"} label={gettext("Home")}><.icon_home /></.tab>
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
    <.link href={@href} class="flex flex-col items-center justify-center gap-0.5 text-slate-500 dark:text-slate-400">
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

  defp icon_home(assigns) do
    ~H"""
    <svg class="h-6 w-6" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" d="m2.25 12 8.954-8.955c.44-.439 1.152-.439 1.591 0L21.75 12M4.5 9.75v10.5a.75.75 0 0 0 .75.75h4.5v-6h4.5v6h4.5a.75.75 0 0 0 .75-.75V9.75" />
    </svg>
    """
  end

  defp icon_logout(assigns) do
    ~H"""
    <svg class="h-5 w-5" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" d="M15.75 9V5.25A2.25 2.25 0 0 0 13.5 3h-6a2.25 2.25 0 0 0-2.25 2.25v13.5A2.25 2.25 0 0 0 7.5 21h6a2.25 2.25 0 0 0 2.25-2.25V15M12 9l-3 3m0 0 3 3m-3-3h12.75" />
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
