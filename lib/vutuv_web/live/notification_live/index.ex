defmodule VutuvWeb.NotificationLive.Index do
  @moduledoc """
  Notifications page. Renders dummy items on first load, then updates live: new
  follower / endorsement / connection events arrive over `Vutuv.Activity`
  (PubSub `"user:<id>"`) and are prepended in real time. Visiting the page also
  clears the unread bell badge in the shell. Items are a LiveView stream, so a
  long-lived session doesn't accumulate them in process memory.
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

    items = dummy_notifications()

    {:ok,
     socket
     |> assign(:page_title, gettext("Notifications"))
     |> assign(:empty?, Enum.empty?(items))
     |> stream(:notifications, items, dom_id: &"notification-#{&1.id}")}
  end

  @impl true
  def handle_info({:new_notification, notification}, socket) do
    item =
      notification
      |> Map.put_new(:kind, "activity")
      # The "live-" prefix keeps live ids out of the dummy id namespace (1..3):
      # the counter starts at 1 on a fresh node, and a bare integer id would
      # collide with a dummy row and update it in place instead of prepending.
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
          <%!-- Show the actor's avatar (linked) when we have a picture. Dummy/seed
          items have a name but no avatar, so they keep the colored kind glyph; the
          name itself still links to the profile via the branch below. --%>
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
              {n.text}
            </p>
            <span class="text-xs uppercase tracking-wide text-slate-400">{n.kind}</span>
          </div>
        </li>
      </ul>

      <p :if={@empty?} class="mt-6 text-slate-400">{gettext("Nothing new yet.")}</p>
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

  # Seed/demo rows. They mirror the real-notification shape (actor_name +
  # actor_param) so the actor's name renders as a profile link, but carry no
  # actor_avatar, so they keep the colored kind glyph instead of a picture.
  # The name renders first, so the text is phrased name-first.
  defp dummy_notifications do
    [
      %{
        id: 1,
        kind: "follower",
        actor_name: "José Daniel",
        actor_param: "jose-daniel",
        text: "started following you."
      },
      %{
        id: 2,
        kind: "endorsement",
        actor_name: "Chris McCord",
        actor_param: "chris-mccord",
        text: "endorsed you for Phoenix."
      },
      %{
        id: 3,
        kind: "connection",
        actor_name: "Wojtek Mach",
        actor_param: "wojtek-mach",
        text: "is now connected with you."
      }
    ]
  end
end
