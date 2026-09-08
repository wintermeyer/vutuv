defmodule VutuvWeb.Admin.DashboardLive do
  @moduledoc """
  The live activity dashboard pinned to the top of the admin home page
  (`/admin`). Embedded with `live_render` in the admin index template (like
  `VutuvWeb.ShellLive` in the app
  layout), so it owns its own socket and refreshes on its own without turning
  the rest of the admin home into a LiveView.

  It gives an admin an at-a-glance pulse of the system: how many members are
  online right now, and how many posts, direct messages and confirmed sign-ups
  landed today versus yesterday, with the timestamp of the last post and
  message. The "currently online" and "new members" cards also list the newest
  ten members behind each figure, each a link straight to that profile, so an
  admin can eyeball who is online or who just joined without searching.

  Every one of those rows also carries the admin's **own** relationship to that
  member: the follow / unfollow pill every listing row on the site wears, plus
  the emerald chip that says when the member follows the admin back. Both are
  read for the whole list in two queries and toggled over the socket, so
  greeting the twenty-two people who signed up today is twenty-two clicks on
  the page an admin already has open rather than twenty-two profile visits. The
  "online now" figure and its list update the instant a member connects or
  disconnects (they ride the `VutuvWeb.Presence` diffs, in-memory, no database);
  the database figures refresh on a gentle timer.

  **The socket does its own access control**, per the standing rule for
  off-router `live_render` children: `/admin` behind the `:admin` pipeline gates
  the page, not this child's socket. The connected mount resolves the viewer
  through `VutuvWeb.Live.InitAssigns.assign_embedded/2` and sends anybody who is
  not an admin away, subscribing to nothing and starting no timer for them.
  """
  use Phoenix.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.UI,
    only: [avatar: 1, card: 1, local_time: 1, delimited_count: 1, follow_button: 1]

  import VutuvWeb.UserHelpers, only: [full_name: 1, following_map: 2]
  import VutuvWeb.UserHTML, only: [profile_relationship_chip: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Dashboard
  alias Vutuv.Social
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.Presence

  # The database figures change slowly, so a relaxed cadence keeps them fresh
  # without polling the database hard; "online now" is instant via presence
  # diffs and never waits for this tick.
  @refresh_interval_ms 15_000

  @impl true
  def mount(_params, session, socket) do
    # The shared preamble for an off-router child: resolves the viewer from the
    # cookie's session token and applies their locale and clock.
    socket =
      socket
      |> InitAssigns.assign_embedded(session)
      |> assign(following_by_id: %{}, follows_me: MapSet.new(), relationship_ids: [])

    cond do
      # The throwaway dead render: the HTTP request that produced it already
      # passed the `:admin` pipeline, and it is replaced the instant the socket
      # connects and re-checks the token.
      not connected?(socket) -> {:ok, assign_figures(socket)}
      admin?(socket.assigns.current_user) -> {:ok, mount_admin(socket)}
      _anyone_else = true -> {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  defp admin?(%User{admin?: true}), do: true
  defp admin?(_viewer), do: false

  defp mount_admin(socket) do
    Presence.subscribe_online()
    schedule_refresh()
    assign_figures(socket)
  end

  defp assign_figures(socket) do
    socket
    |> assign_online()
    |> assign_snapshot()
    |> assign_newest_members()
    |> assign(:gender_breakdown, Dashboard.gender_breakdown())
    |> assign_relationships()
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()

    {:noreply,
     socket
     |> assign_online()
     |> assign_snapshot()
     |> assign_newest_members()
     |> assign_relationships()}
  end

  # A member connected or disconnected somewhere: re-read the in-memory online
  # set so the "online now" count and its member list are always current. The
  # newest-members list can't change on presence, so it waits for the timer.
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, socket |> assign_online() |> assign_relationships()}

  def handle_info(_other, socket), do: {:noreply, socket}

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)

  defp assign_snapshot(socket), do: assign(socket, Dashboard.activity_snapshot())

  # Reads the in-memory presence set once and derives both the count and the
  # linked list of who is online from it.
  defp assign_online(socket) do
    online_ids = Presence.online_ids()

    socket
    |> assign(:online_count, MapSet.size(online_ids))
    |> assign(:online_members, Dashboard.online_members(online_ids))
  end

  defp assign_newest_members(socket),
    do: assign(socket, :newest_members, Dashboard.newest_members())

  # ── The admin's own relationship to the people in the two lists ────────────

  # The follow pill on a row, the site's ordinary follow reached from here: the
  # same two events `VutuvWeb.PostLive.Feed` and the profile fire, refusals and
  # all (see `Social.follow/2`).
  @impl true
  def handle_event(_event, _params, %{assigns: %{current_user: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("follow", %{"followee" => followee_id}, socket) do
    Social.follow(socket.assigns.current_user, followee_id)
    {:noreply, assign_following(socket)}
  end

  # Scoped to the viewer by `unfollow!/2`, so a tampered id can only ever drop
  # an edge the admin owns.
  def handle_event("unfollow", %{"id" => follow_id}, socket) do
    Social.unfollow!(socket.assigns.current_user.id, follow_id)
    {:noreply, assign_following(socket)}
  end

  # Both directions for the whole page: the admin's outbound edges (the pill,
  # and the id an unfollow needs) and the ids of the members who follow the
  # admin (the chip).
  #
  # Guarded on the id list rather than run on every pass, because a presence
  # diff is site-wide socket churn — `ShellLive` tracks on every page — while
  # who is in these two lists changes far more rarely. The dead render pays for
  # it too: it is thrown away, but without it every row paints a "Follow" pill
  # that flips the moment the socket connects.
  defp assign_relationships(socket) do
    members = listed_members(socket)

    if Enum.map(members, & &1.id) == socket.assigns.relationship_ids,
      do: socket,
      else: load_relationships(socket, members)
  end

  # After the admin's own follow or unfollow. Only the outbound half is re-read:
  # the admin writing their own edge cannot change who follows *them*, so asking
  # again would be a query per click that can only ever answer the same thing.
  defp assign_following(socket) do
    members = listed_members(socket)
    assign(socket, :following_by_id, following_map(socket.assigns.current_user, members))
  end

  # Both lists, in id order so the result doubles as the guard's cache key, and
  # without the admin's own row: they are in the "currently online" list because
  # they are reading this page, and nobody follows themselves.
  defp listed_members(socket) do
    (socket.assigns.online_members ++ socket.assigns.newest_members)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&(&1.id == socket.assigns.current_user_id))
    |> Enum.sort_by(& &1.id)
  end

  # `following_map/2` is the app's one batched "which of these do I follow", and
  # its `%{followee_id => follow_id}` is the shape every other people listing
  # binds to `following_by_id`. Both helpers answer empty for a nil viewer.
  defp load_relationships(socket, members) do
    ids = Enum.map(members, & &1.id)

    socket
    |> assign(:following_by_id, following_map(socket.assigns.current_user, members))
    |> assign(:follows_me, Social.inbound_follower_ids(socket.assigns.current_user_id, ids))
    |> assign(:relationship_ids, ids)
  end

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

      <%!-- `grid-cols-1` is load-bearing below `sm`, not a spelling of the
      default: an implicit track is min-content sized, so the widest member row
      pushed the card past a 375px phone. See `mobile_overflow_test.exs`. --%>
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
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
          <.member_list
            id="online-members"
            members={@online_members}
            empty={gettext("Nobody is online right now.")}
            current_user_id={@current_user_id}
            following_by_id={@following_by_id}
            follows_me={@follows_me}
          />
        </.card>

        <.stat_tile
          id="stat-members"
          title={gettext("New members")}
          today={@registrations_today}
          yesterday={@registrations_yesterday}
          last_at={nil}
        >
          <:extra>
            <.member_list
              id="newest-members"
              members={@newest_members}
              empty={gettext("No members yet.")}
              current_user_id={@current_user_id}
              following_by_id={@following_by_id}
              follows_me={@follows_me}
            />
          </:extra>
        </.stat_tile>
      </div>

      <div class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2">
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
      </div>

      <div class="mt-4">
        <.gender_card breakdown={@gender_breakdown} />
      </div>
    </section>
    """
  end

  # The membership breakdown by gender, the single reason that field is asked
  # for (`Vutuv.Accounts.User.gender`).
  #
  # Two things here are the feature, not decoration. Every share is computed
  # over the members who ANSWERED, never over all members, and the card says so
  # underneath: the answer is voluntary, so most rows carry none, and a
  # percentage taken over everybody would report silence as a gender. And the
  # unanswered figure is shown rather than hidden, because it is the honest
  # measure of how much this breakdown is worth on any given day.
  #
  # It carries no share bars or chart. The numbers moved into this card from a
  # column that preselected "male" for years, so the figures are approximate in
  # a way no graphic should paper over.
  attr(:breakdown, :map, required: true)

  defp gender_card(assigns) do
    ~H"""
    <.card>
      <p class="text-xs font-bold uppercase tracking-wider text-slate-500 dark:text-slate-400">
        {gettext("Gender")}
      </p>
      <dl id="stat-gender" class="mt-3 grid grid-cols-3 gap-4">
        <div :for={{value, count} <- @breakdown.counts} data-gender={value}>
          <dt class="text-xs text-slate-600 dark:text-slate-400">{User.gender_label(value)}</dt>
          <dd class="text-2xl font-bold tabular-nums text-slate-900 dark:text-slate-100">
            {delimited_count(count)}
          </dd>
          <dd class="text-xs text-slate-600 dark:text-slate-400">
            {gender_share(count, @breakdown.answered)}
          </dd>
        </div>
      </dl>
      <p class="mt-3 border-t border-slate-200 pt-3 text-xs text-slate-600 dark:border-slate-800 dark:text-slate-400">
        {gettext("Shares are of the %{answered} members who answered. %{unanswered} gave no answer.",
          answered: delimited_count(@breakdown.answered),
          unanswered: delimited_count(@breakdown.unanswered)
        )}
      </p>
    </.card>
    """
  end

  # Whole percent, and "—" while nobody has answered: a "0%" against a zero
  # denominator would read as a measured result rather than as no data.
  defp gender_share(_count, 0), do: "—"
  defp gender_share(count, answered), do: "#{round(count * 100 / answered)}%"

  # A card's linked people list: up to ten members, each an avatar + name row
  # that navigates straight to that profile, so an admin can eyeball who is
  # online or who just signed up without searching. Falls back to a muted empty
  # line. Newest first (the caller orders the list).
  #
  # Each row also carries the admin's own side of the relationship, split the
  # way `.claude/rules/design.md` asks: **an act is a button, a status is not**.
  # The follow pill takes the action column on the right; the "follows you" /
  # "connected" chip takes a line of its own under the handle, because sharing
  # the handle's line cut it to "@nah…" on a 375px phone.
  attr(:id, :string, required: true)
  attr(:members, :list, required: true)
  attr(:empty, :string, required: true)
  attr(:current_user_id, :any, required: true)
  attr(:following_by_id, :map, required: true)
  attr(:follows_me, MapSet, required: true)

  def member_list(assigns) do
    ~H"""
    <ul
      :if={@members != []}
      id={@id}
      role="list"
      class="mt-4 space-y-1 border-t border-slate-100 pt-3 dark:border-slate-800"
    >
      <li :for={member <- @members} class="flex items-center gap-2">
        <.link
          navigate={~p"/#{member}"}
          class="group flex min-w-0 flex-1 items-start gap-3 rounded-lg p-1.5 hover:bg-slate-50 dark:hover:bg-slate-800/60"
        >
          <.avatar user={member} size="sm" />
          <span class="min-w-0 flex-1">
            <span class="block truncate text-sm font-semibold text-slate-900 group-hover:text-brand-700 dark:text-slate-100 dark:group-hover:text-brand-400">
              {full_name(member)}
            </span>
            <span class="block truncate text-xs text-slate-600 dark:text-slate-400">
              @{member.username}
            </span>
            <span :if={MapSet.member?(@follows_me, member.id)} class="mt-1 flex">
              <.profile_relationship_chip
                follow_id={Map.get(@following_by_id, member.id)}
                follows_viewer?={true}
              />
            </span>
          </span>
        </.link>
        <.follow_button
          :if={@current_user_id && member.id != @current_user_id}
          variant="text"
          live?
          follower_id={@current_user_id}
          followee_id={member.id}
          follow_id={Map.get(@following_by_id, member.id)}
        />
      </li>
    </ul>
    <p
      :if={@members == []}
      id={@id}
      class="mt-4 border-t border-slate-100 pt-3 text-xs text-slate-600 dark:border-slate-800 dark:text-slate-400"
    >
      {@empty}
    </p>
    """
  end

  # One activity tile: today's figure large, yesterday's below it, and - when
  # the tile tracks dated rows - the timestamp of the most recent one.
  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:today, :integer, required: true)
  attr(:yesterday, :integer, required: true)
  attr(:last_at, :any, default: nil)
  slot(:extra, doc: "optional content appended below the tile's figures")

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
      {render_slot(@extra)}
    </.card>
    """
  end
end
