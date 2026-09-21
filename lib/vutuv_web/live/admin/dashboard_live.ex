defmodule VutuvWeb.Admin.DashboardLive do
  @moduledoc """
  The live activity dashboard pinned to the top of the admin home page
  (`/admin`). Embedded with `live_render` in the admin index template (like
  `VutuvWeb.ShellLive` in the app
  layout), so it owns its own socket and refreshes on its own without turning
  the rest of the admin home into a LiveView.

  It gives an admin an at-a-glance pulse of the system in four figure tiles —
  confirmed sign-ups today, members online right now, posts and direct messages
  today, each against yesterday — and below them **one** people card that shows
  either the newest ten members or who is online, switched by a segment control
  or by tapping the matching tile. New members come first: on a phone that is
  what an admin opens the page for, and two stacked lists put everybody online
  between them and today's sign-ups. A new member's row also says where they
  live (city and country of their first address) and their three most-endorsed
  tags, with the count of the rest.

  Every row also carries the admin's **own** relationship to that member: the
  follow / unfollow pill every listing row on the site wears, plus the emerald
  chip that says when the member follows the admin back. Both are read for both
  lists in two queries and toggled over the socket, so greeting the twenty-two
  people who signed up today is twenty-two clicks on the page an admin already
  has open rather than twenty-two profile visits. The "online now" figure and
  its list update the instant a member connects or disconnects (they ride the
  `VutuvWeb.Presence` diffs, in-memory, no database); the database figures
  refresh on a gentle timer.

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
    only: [
      avatar: 1,
      card: 1,
      chip: 1,
      compact_count: 1,
      delimited_count: 1,
      detail_icon: 1,
      follow_button: 1,
      local_time: 1
    ]

  import VutuvWeb.UserHelpers, only: [full_name: 1, following_map: 2, tag_summary_map: 2]
  import VutuvWeb.UserHTML, only: [profile_relationship_chip: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Countries
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
      |> assign(:tab, "new")

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

  # The newest members plus what their rows show beyond a name: where they live
  # and their top tags, each batched in one query for the whole list.
  defp assign_newest_members(socket) do
    members = Dashboard.newest_members()

    assign(socket,
      newest_members: members,
      places: Dashboard.member_places(Enum.map(members, & &1.id)),
      tag_summaries: tag_summary_map(members, 3)
    )
  end

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

  # The people card's switch, from the segment control or a figure tile. Kept
  # in the socket only: a reconnect lands on the new members again, which is
  # the card's default anyway.
  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["new", "online"],
    do: {:noreply, assign(socket, :tab, tab)}

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

      <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.figure_tile
          id="tile-new"
          tab="new"
          current={@tab}
          title={gettext("New today")}
          figure={@registrations_today}
          figure_id="stat-members-today"
        >
          <.yesterday_and_latest id="stat-members" yesterday={@registrations_yesterday} />
        </.figure_tile>
        <.figure_tile
          id="tile-online"
          tab="online"
          current={@tab}
          title={pgettext("admin dashboard", "Online")}
          figure={@online_count}
          figure_id="stat-online"
          dot
        >
          <span class="mt-1 block text-xs text-slate-600 dark:text-slate-400">
            {pgettext("admin dashboard", "right now")}
          </span>
        </.figure_tile>
        <.figure_tile id="tile-posts" title={gettext("Posts")} figure={@posts_today} figure_id="stat-posts-today">
          <.yesterday_and_latest id="stat-posts" yesterday={@posts_yesterday} last_at={@last_post_at} />
        </.figure_tile>
        <.figure_tile
          id="tile-messages"
          title={gettext("Messages")}
          figure={@messages_today}
          figure_id="stat-messages-today"
        >
          <.yesterday_and_latest id="stat-messages" yesterday={@messages_yesterday} last_at={@last_message_at} />
        </.figure_tile>
      </div>

      <section class="mt-4 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200 sm:p-6 dark:bg-slate-900 dark:ring-slate-800">
        <div class="flex gap-1 rounded-xl bg-slate-100 p-1 dark:bg-slate-800">
          <.segment
            tab="new"
            current={@tab}
            short={pgettext("admin dashboard", "New")}
            full={gettext("New members")}
          />
          <.segment
            tab="online"
            current={@tab}
            short={pgettext("admin dashboard", "Online")}
            full={gettext("Currently online")}
            dot
          />
        </div>

        <.member_list
          :if={@tab == "new"}
          id="newest-members"
          members={@newest_members}
          places={@places}
          tag_summaries={@tag_summaries}
          empty={gettext("No members yet.")}
          current_user_id={@current_user_id}
          following_by_id={@following_by_id}
          follows_me={@follows_me}
        />
        <.member_list
          :if={@tab == "online"}
          id="online-members"
          members={@online_members}
          empty={gettext("Nobody is online right now.")}
          current_user_id={@current_user_id}
          following_by_id={@following_by_id}
          follows_me={@follows_me}
        />
      </section>

      <div class="mt-4">
        <.gender_card breakdown={@gender_breakdown} />
      </div>
    </section>
    """
  end

  # One figure tile. The two whose list the people card can show (`tab`) are
  # buttons that switch it, on a phone the bigger target of the two, and wear a
  # ring while their list is the one on show. The rest are plain sections.
  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:figure, :integer, required: true)
  attr(:figure_id, :string, required: true)
  attr(:tab, :string, default: nil)
  attr(:current, :string, default: nil)
  attr(:dot, :boolean, default: false)
  slot(:inner_block, required: true)

  # Spans, not paragraphs, inside: a button may hold only phrasing content.
  defp figure_tile(assigns) do
    ~H"""
    <.dynamic_tag
      tag_name={if @tab, do: "button", else: "section"}
      id={@id}
      type={@tab && "button"}
      phx-click={@tab && "tab"}
      phx-value-tab={@tab}
      aria-pressed={@tab && to_string(@tab == @current)}
      class={[
        "flex h-full w-full min-w-0 flex-col items-start rounded-2xl bg-white p-3.5 text-left shadow-sm dark:bg-slate-900",
        @tab && "transition-colors hover:bg-slate-50 dark:hover:bg-slate-800/60",
        if(@tab && @tab == @current,
          do: "ring-2 ring-brand-600 dark:ring-brand-400",
          else: "ring-1 ring-slate-200 dark:ring-slate-800"
        )
      ]}
    >
      <span class="flex items-center gap-2 text-xs font-bold uppercase tracking-wider text-slate-500 dark:text-slate-400">
        {@title}
        <span :if={@dot} class="h-2.5 w-2.5 rounded-full bg-emerald-500 ring-4 ring-emerald-500/15" aria-hidden="true">
        </span>
      </span>
      <span id={@figure_id} class="mt-1 text-3xl font-bold tabular-nums text-slate-900 dark:text-slate-100">
        {delimited_count(@figure)}
      </span>
      {render_slot(@inner_block)}
    </.dynamic_tag>
    """
  end

  # A tile's yesterday line and, for the dated tiles, the newest row's time. The
  # time is pinned to day, month and clock: the year would push the line past a
  # half-width tile on a 375px phone.
  attr(:id, :string, required: true)
  attr(:yesterday, :integer, required: true)
  attr(:last_at, :any, default: nil)

  defp yesterday_and_latest(assigns) do
    ~H"""
    <span id={"#{@id}-yesterday"} class="mt-1 block text-xs text-slate-600 dark:text-slate-400">
      {gettext("yesterday %{formatted}", formatted: delimited_count(@yesterday))}
    </span>
    <span :if={@last_at} class="mt-0.5 block text-xs text-slate-600 dark:text-slate-400">
      {gettext("Latest")} <.local_time at={@last_at} id={"#{@id}-last"} format="%d.%m. %H:%M" />
    </span>
    """
  end

  # One half of the people card's switch. Below `sm` it says only "New" or
  # "Online", which is all half a phone has room for.
  #
  # No count beside the label: the tiles above carry the figures, and the new
  # members' figure counts today while the list shows the newest ten, so a
  # quiet day put "New 0" above ten names.
  attr(:tab, :string, required: true)
  attr(:current, :string, required: true)
  attr(:short, :string, required: true)
  attr(:full, :string, required: true)
  attr(:dot, :boolean, default: false)

  defp segment(assigns) do
    ~H"""
    <button
      type="button"
      id={"dashboard-tab-#{@tab}"}
      phx-click="tab"
      phx-value-tab={@tab}
      aria-pressed={to_string(@tab == @current)}
      class={[
        "flex h-10 min-w-0 flex-1 items-center justify-center gap-1.5 rounded-lg px-2 text-sm font-semibold transition-colors",
        if(@tab == @current,
          do:
            "bg-white text-slate-900 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:text-slate-100 dark:ring-slate-700",
          else: "text-slate-600 hover:text-slate-900 dark:text-slate-400 dark:hover:text-slate-100"
        )
      ]}
    >
      <span :if={@dot} class="h-2 w-2 flex-none rounded-full bg-emerald-500" aria-hidden="true"></span>
      <span data-label="short" class="truncate sm:hidden">{@short}</span>
      <span data-label="full" class="hidden truncate sm:inline">{@full}</span>
    </button>
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

  # The people card's list: up to ten members, each an avatar + name row that
  # navigates straight to that profile, so an admin can eyeball who is online or
  # who just signed up without searching. Falls back to a muted empty line.
  # Newest first (the caller orders the list).
  #
  # Each row also carries the admin's own side of the relationship, split the
  # way `.claude/rules/design.md` asks: **an act is a button, a status is not**.
  # The follow pill takes the action column on the right; the "follows you" /
  # "connected" chip takes a line of its own under the handle, because sharing
  # the handle's line cut it to "@nah…" on a 375px phone.
  #
  # The new members' list also passes `places` and `tag_summaries`, so its rows
  # say where the member lives and show their three most-endorsed tags with the
  # count of the rest. The tag line runs under the follow pill rather than
  # beside it, so on a phone the pill costs the tags no width; its inset lines
  # it up with the name (the link's 6px padding, the 36px avatar and the 12px
  # gap). The tags are labels, not links: at text-xs they would be targets a
  # thumb cannot hit, and the row already links to the profile that lists them.
  attr(:id, :string, required: true)
  attr(:members, :list, required: true)
  attr(:empty, :string, required: true)
  attr(:places, :map, default: %{})
  attr(:tag_summaries, :map, default: %{})
  attr(:current_user_id, :any, required: true)
  attr(:following_by_id, :map, required: true)
  attr(:follows_me, MapSet, required: true)

  def member_list(assigns) do
    ~H"""
    <ul :if={@members != []} id={@id} role="list" class="mt-2">
      <li
        :for={member <- @members}
        :key={member.id}
        id={"#{@id}-#{member.id}"}
        class="border-t border-slate-100 pb-2 pt-1 first:border-t-0 dark:border-slate-800"
      >
        <div class="flex items-start gap-2">
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
              <.member_place place={place_line(@places[member.id])} />
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
        </div>
        <.member_tags summary={@tag_summaries[member.id]} />
      </li>
    </ul>
    <p :if={@members == []} id={@id} class="mt-4 text-xs text-slate-600 dark:text-slate-400">
      {@empty}
    </p>
    """
  end

  attr(:place, :string, default: nil)

  defp member_place(%{place: nil} = assigns), do: ~H""

  defp member_place(assigns) do
    ~H"""
    <span data-member-place class="mt-0.5 flex min-w-0 items-center gap-1 text-xs text-slate-600 dark:text-slate-400">
      <.detail_icon name="map-pin" class="h-3.5 w-3.5 shrink-0" />
      <span class="truncate">{@place}</span>
    </span>
    """
  end

  # "City, Country" in the reader's language, or nil when neither is known.
  defp place_line(nil), do: nil

  defp place_line(%{city: city, country: country}) do
    case Enum.reject([city, Countries.localize_english_name(country)], &(&1 in [nil, ""])) do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  # The chips truncate: a tag name runs to 255 characters, and an unbroken one
  # would otherwise push the row past a phone's width.
  attr(:summary, :map, default: nil)

  defp member_tags(%{summary: nil} = assigns), do: ~H""

  defp member_tags(assigns) do
    ~H"""
    <div class="mt-0.5 flex flex-wrap items-center gap-1.5 pl-[3.375rem]">
      <.chip :for={user_tag <- @summary.top} size="sm" class="min-w-0 max-w-full" data-member-tag>
        <span class="truncate">{user_tag.tag.name}</span>
      </.chip>
      <span
        :if={@summary.total > length(@summary.top)}
        data-member-more-tags
        class="whitespace-nowrap text-xs font-medium text-slate-600 dark:text-slate-400"
      >
        {ngettext("+1 more tag", "+%{formatted} more tags", @summary.total - length(@summary.top),
          formatted: compact_count(@summary.total - length(@summary.top))
        )}
      </span>
    </div>
    """
  end
end
