defmodule VutuvWeb.Admin.DashboardLive do
  @moduledoc """
  The live activity dashboard pinned to the top of the admin home page
  (`/admin`). Embedded with `live_render` in the admin index template (like
  `VutuvWeb.MemberCountLive` on the landing page and `ShellLive` in the app
  layout), so it owns its own socket and refreshes on its own without turning
  the rest of the admin home into a LiveView.

  It gives an admin an at-a-glance pulse of the system: how many members are
  online right now, and how many posts, direct messages and confirmed sign-ups
  landed today versus yesterday, with the timestamp of the last post and
  message. The "online now" figure updates the instant a member connects or
  disconnects (it rides the `VutuvWeb.Presence` diffs, in-memory, no database);
  the database figures refresh on a gentle timer.

  Access control is the host page's job: `/admin` is gated by the `:admin`
  pipeline (403 for non-admins), so only an admin is ever handed the signed
  session that lets this embedded LiveView's socket connect.
  """
  use Phoenix.LiveView

  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.UI, only: [card: 1, local_time: 1, delimited_count: 1]

  alias Vutuv.Dashboard
  alias VutuvWeb.Presence

  # The database figures change slowly, so a relaxed cadence keeps them fresh
  # without polling the database hard; "online now" is instant via presence
  # diffs and never waits for this tick.
  @refresh_interval_ms 15_000

  @impl true
  def mount(_params, session, socket) do
    # Embedded outside the admin live_session, so re-apply the request locale
    # (the labels are gettext, the admin UI is German) the way ShellLive does.
    VutuvWeb.LiveLocale.put_locale(session)

    if connected?(socket) do
      Presence.subscribe_online()
      schedule_refresh()
    end

    {:ok, socket |> assign_online_count() |> assign_snapshot()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, socket |> assign_online_count() |> assign_snapshot()}
  end

  # A member connected or disconnected somewhere: re-read the in-memory online
  # set (no database) so the "online now" tile is always current.
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, assign_online_count(socket)}

  def handle_info(_other, socket), do: {:noreply, socket}

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)

  defp assign_snapshot(socket), do: assign(socket, Dashboard.activity_snapshot())

  defp assign_online_count(socket),
    do: assign(socket, :online_count, MapSet.size(Presence.online_ids()))

  @impl true
  def render(assigns) do
    ~H"""
    <section id="admin-live-dashboard" class="mb-10">
      <div class="mb-3 flex items-baseline gap-2">
        <h2 class="text-xs font-bold uppercase tracking-wider text-slate-500 dark:text-slate-400">
          {gettext("Live activity")}
        </h2>
        <span class="text-xs text-slate-600 dark:text-slate-400">
          {gettext("updates automatically")}
        </span>
      </div>

      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.card>
          <div class="flex items-center justify-between">
            <p class="text-xs font-bold uppercase tracking-wider text-slate-500 dark:text-slate-400">
              {gettext("Currently online")}
            </p>
            <span
              class="h-2.5 w-2.5 rounded-full bg-emerald-500 ring-4 ring-emerald-500/15"
              aria-hidden="true"
            >
            </span>
          </div>
          <p
            id="stat-online"
            class="mt-2 text-3xl font-bold tabular-nums text-slate-900 dark:text-slate-100"
          >
            {delimited_count(@online_count)}
          </p>
          <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
            {gettext("Members online right now")}
          </p>
        </.card>

        <.stat_tile
          id="stat-posts"
          title={gettext("Posts")}
          today={@posts_today}
          yesterday={@posts_yesterday}
          last_at={@last_post_at}
        />
        <.stat_tile
          id="stat-messages"
          title={gettext("Direct messages")}
          today={@messages_today}
          yesterday={@messages_yesterday}
          last_at={@last_message_at}
        />
        <.stat_tile
          id="stat-members"
          title={gettext("New members")}
          today={@registrations_today}
          yesterday={@registrations_yesterday}
          last_at={nil}
        />
      </div>
    </section>
    """
  end

  # One activity tile: today's figure large, yesterday's below it, and - when
  # the tile tracks dated rows - the timestamp of the most recent one.
  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:today, :integer, required: true)
  attr(:yesterday, :integer, required: true)
  attr(:last_at, :any, default: nil)

  def stat_tile(assigns) do
    ~H"""
    <.card>
      <p class="text-xs font-bold uppercase tracking-wider text-slate-500 dark:text-slate-400">
        {@title}
      </p>
      <p
        id={"#{@id}-today"}
        class="mt-2 text-3xl font-bold tabular-nums text-slate-900 dark:text-slate-100"
      >
        {delimited_count(@today)}
      </p>
      <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">{gettext("Today")}</p>

      <dl class="mt-3 space-y-1.5 border-t border-slate-100 pt-3 text-sm dark:border-slate-800">
        <div class="flex items-center justify-between gap-2">
          <dt class="text-slate-600 dark:text-slate-400">{gettext("Yesterday")}</dt>
          <dd
            id={"#{@id}-yesterday"}
            class="font-semibold tabular-nums text-slate-700 dark:text-slate-200"
          >
            {delimited_count(@yesterday)}
          </dd>
        </div>
        <div :if={@last_at} class="flex items-center justify-between gap-2">
          <dt class="text-slate-600 dark:text-slate-400">{gettext("Latest")}</dt>
          <dd class="font-semibold text-slate-700 dark:text-slate-200">
            <.local_time at={@last_at} id={"#{@id}-last"} format="%d.%m.%Y %H:%M" />
          </dd>
        </div>
      </dl>
    </.card>
    """
  end
end
