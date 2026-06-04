defmodule VutuvWeb.ShellLive do
  @moduledoc """
  The app shell — the sticky top bar plus the mobile bottom tab bar. Rendered
  once and embedded in the `app` layout via `live_render` (sticky), so it
  persists across live navigation and carries the live unread badges (messages,
  notifications) that update in real time from `Vutuv.Activity` (PubSub on
  `"user:<id>"`).

  Uses `Phoenix.LiveView` directly (no `app` layout) to avoid wrapping itself.
  The notification badge is the real unread count (events newer than the
  user's read marker, via `Vutuv.Activity.unread_notification_count/1`); the
  messages badge stays dummy until messages get persistence.
  """
  use Phoenix.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Activity

  @impl true
  def mount(_params, session, socket) do
    user_id = session["user_id"]
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
     |> assign(:user_param, session["user_param"])
     |> assign(:user_avatar, session["user_avatar"])
     |> assign(:messages_count, initial_count(path, "/messages", user_id, &dummy_messages/1))
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

  def handle_info({:new_message, _m}, socket),
    do: {:noreply, update(socket, :messages_count, &(&1 + 1))}

  def handle_info(:notifications_read, socket),
    do: {:noreply, assign(socket, :notifications_count, 0)}

  def handle_info(:messages_read, socket),
    do: {:noreply, assign(socket, :messages_count, 0)}

  def handle_info(_other, socket), do: {:noreply, socket}

  # Messages have no persistence yet (see MessageLive); seed the badge with a
  # fixed value for logged-in users until they do.
  defp dummy_messages(nil), do: 0
  defp dummy_messages(_user_id), do: 2

  defp initials(nil), do: "?"

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      i -> i
    end
  end

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
              href={~p"/listings/most_followed_users"}
              class="rounded-md px-3 py-2 text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"
            >
              {gettext("Network")}
            </.link>
            <a href="#" class="rounded-md px-3 py-2 text-slate-400 dark:text-slate-500">{gettext("Jobs")}</a>
          </nav>

          <div class="ml-auto flex items-center gap-1">
            <.link
              href={~p"/search_queries/new"}
              title={gettext("Search")}
              class="hidden h-10 w-10 items-center justify-center rounded-full text-slate-500 hover:bg-slate-100 sm:flex dark:text-slate-400 dark:hover:bg-slate-800"
            >
              <.icon_search />
            </.link>

            <%= if @user_id do %>
              <.link
                href={~p"/messages"}
                title={gettext("Messages")}
                class="relative hidden h-10 w-10 items-center justify-center rounded-full text-slate-500 hover:bg-slate-100 md:flex dark:text-slate-400 dark:hover:bg-slate-800"
              >
                <.icon_envelope />
                <.count_badge count={@messages_count} />
              </.link>
              <.link
                href={~p"/notifications"}
                title={gettext("Notifications")}
                class="relative hidden h-10 w-10 items-center justify-center rounded-full text-slate-500 hover:bg-slate-100 md:flex dark:text-slate-400 dark:hover:bg-slate-800"
              >
                <.icon_bell />
                <.count_badge count={@notifications_count} />
              </.link>
              <.link href={~p"/users/#{@user_param}"} title={@user_name} class="ml-1 shrink-0">
                <%= if @user_avatar do %>
                  <img src={@user_avatar} alt={@user_name} class="h-9 w-9 rounded-full object-cover" />
                <% else %>
                  <span class="flex h-9 w-9 items-center justify-center rounded-full bg-brand-700 text-sm font-bold text-white">
                    {initials(@user_name)}
                  </span>
                <% end %>
              </.link>
              <.link
                href={~p"/sessions/#{@user_param}"}
                method="delete"
                title={gettext("Log out")}
                class="flex h-10 w-10 items-center justify-center rounded-full text-slate-400 hover:bg-slate-100 dark:hover:bg-slate-800"
              >
                <.icon_logout />
              </.link>
            <% else %>
              <.link
                href={~p"/sessions/new"}
                class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
              >
                {gettext("Log in")}
              </.link>
            <% end %>
          </div>
        </div>
      </header>

      <%!-- Mobile bottom tab bar (fixed; content in the layout reserves space) --%>
      <nav class="fixed inset-x-0 bottom-0 z-30 grid h-16 grid-cols-5 border-t border-slate-200 bg-white/95 backdrop-blur md:hidden dark:border-slate-800 dark:bg-slate-900/95">
        <.tab href={~p"/"} label={gettext("Home")}><.icon_home /></.tab>
        <.tab href={~p"/search_queries/new"} label={gettext("Search")}><.icon_search /></.tab>
        <.tab href="#" label={gettext("Jobs")}><.icon_briefcase /></.tab>
        <.tab href={~p"/messages"} label={gettext("Messages")} count={@messages_count}><.icon_envelope /></.tab>
        <.tab href={~p"/notifications"} label={gettext("Alerts")} count={@notifications_count}><.icon_bell /></.tab>
      </nav>
    </div>
    """
  end

  ## Components

  attr(:count, :integer, default: 0)

  defp count_badge(assigns) do
    ~H"""
    <span
      :if={@count > 0}
      class="absolute -right-0.5 -top-0.5 flex h-[18px] min-w-[18px] items-center justify-center rounded-full bg-accent px-1 text-[11px] font-bold text-white ring-2 ring-white dark:ring-slate-900"
    >
      {@count}
    </span>
    """
  end

  attr(:href, :string, required: true)
  attr(:label, :string, required: true)
  attr(:count, :integer, default: 0)
  slot(:inner_block, required: true)

  defp tab(assigns) do
    ~H"""
    <.link href={@href} class="flex flex-col items-center justify-center gap-0.5 text-slate-500 dark:text-slate-400">
      <span class="relative">
        {render_slot(@inner_block)}
        <.count_badge count={@count} />
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

  defp icon_home(assigns) do
    ~H"""
    <svg class="h-6 w-6" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" d="m2.25 12 8.954-8.955c.44-.439 1.152-.439 1.591 0L21.75 12M4.5 9.75v10.5a.75.75 0 0 0 .75.75h4.5v-6h4.5v6h4.5a.75.75 0 0 0 .75-.75V9.75" />
    </svg>
    """
  end

  defp icon_briefcase(assigns) do
    ~H"""
    <svg class="h-6 w-6" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" d="M20.25 14.15v4.25a2.18 2.18 0 0 1-1.87 2.18 48 48 0 0 1-12.76 0 2.18 2.18 0 0 1-1.87-2.18v-4.25M21 8.71v3.78A48 48 0 0 1 3 12.49V8.71a2.18 2.18 0 0 1 1.84-2.18A48 48 0 0 1 12 6c2.4 0 4.76.18 7.16.53A2.18 2.18 0 0 1 21 8.71ZM15.75 6V5.25A2.25 2.25 0 0 0 13.5 3h-3a2.25 2.25 0 0 0-2.25 2.25V6" />
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
end
