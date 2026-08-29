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

  import VutuvWeb.UI,
    only: [
      button: 1,
      compact_count: 1,
      count_badge: 1,
      delimited_count: 1,
      gutter_class: 0,
      icon_bookmark: 1,
      name_initials: 1,
      presence_dot: 1
    ]

  import VutuvWeb.UserHelpers, only: [full_name: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.ContentFilters
  alias Vutuv.Dashboard
  alias Vutuv.DayClock
  alias Vutuv.Organizations
  alias Vutuv.PeopleCounter
  alias Vutuv.Posts
  alias Vutuv.Prefs
  alias Vutuv.Social
  alias Vutuv.WebPush
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.NotificationLine
  alias VutuvWeb.PostTeaser
  alias VutuvWeb.Presence

  # How long one browser-tab frame really stands (issue #1681), which is what
  # the server's window has to be measured in — it is the only thing deciding
  # whether a second arrival still reaches a running animation as a count.
  #
  # The hook asks for a second and the browser gives it two: a hidden tab's
  # timers are aligned to whole seconds, so a one-second timeout re-armed just
  # after a wake-up misses the next boundary and waits for the one after.
  # Measured in headless Chrome 151 against a real socket: frames at 0, 2.0,
  # 4.0 s and the title handed back at 6.0. Sizing the window at the requested
  # second instead closed it at 3 s, while the browser was still on frame two.
  @frame_ms 2_000

  @impl true
  def mount(_params, session, socket) do
    # The shell mounts outside the `live_session` (embedded via live_render),
    # so InitAssigns never runs for it — apply the session locale here.
    VutuvWeb.LiveLocale.put_viewer(session)

    # When the shell mounts ON the messages/notifications page itself, that
    # badge starts at zero. Relying only on the page's read-broadcast races the
    # shell's subscribe on full page loads (the broadcast can fire first).
    path = session["path"] || ""

    # The people total in the middle of the bar is public and on every page, so
    # every socket subscribes — logged in or not. `Vutuv.PeopleCounter`
    # coalesces a burst of sign-ups into at most one message per second, so this
    # fan-out costs one message per connected tab per second of actual change.
    if connected?(socket), do: PeopleCounter.subscribe()

    socket =
      if connected?(socket) do
        # The live socket authenticates from the cookie's `session_token` — the
        # same source of truth ConfigureSession / Live.InitAssigns use — never
        # the curated shell_session map (signed, not encrypted, so replayable)
        # nor the bare cookie `user_id` a revoked device still carries. So a
        # remotely logged-out device or a suspended member drops to the anonymous
        # shell on reconnect, and a replayed shell_session payload cannot render
        # another member's chrome or subscribe to their "user:<id>" unread-badge
        # topic. All identity therefore comes from the resolved user, not the
        # curated map.
        mount_authenticated(socket, InitAssigns.session_user(session), session, path)
      else
        # The throwaway dead render, authenticated by the HTTP request that built
        # shell_session/1 from the validated current_user — so its curated
        # display fields are safe to show, and the whole render is replaced the
        # instant the socket connects and re-checks the token. It computes no
        # counts / presence — those are connected-only anyway.
        mount_static(socket, session, path)
      end

    {:ok, socket}
  end

  # The dead render's identity: the curated display fields LayoutHTML.shell_session/1
  # signs into `data-phx-session`. Phoenix.LiveView.Static merges the raw browser
  # session UNDER them, so a cookie pointing at a since-deleted or UUID-re-keyed
  # account (every pre-cutover session is now one) leaks its bare `user_id` here
  # with no profile fields. Key "logged in" off `user_param`, which only
  # shell_session sets, so such a session renders the anonymous shell instead of
  # the logged-in chrome that would crash on `~p"/#{nil}"`. cast_or_nil also
  # tolerates the integer ids in cookies from before the UUID cutover.
  defp mount_static(socket, session, path) do
    socket = assign(socket, :acting_as, nil)

    user_param = session["user_param"]
    user_id = user_param && Vutuv.UUIDv7.cast_or_nil(session["user_id"])

    socket
    # The mode the HTTP request behind this dead render already verified. It is
    # replaced the instant the socket connects and re-asks the roles table.
    |> assign(:acting_as_name, session["acting_as_name"])
    |> assign(:acting_as_path, session["acting_as_path"])
    |> assign(:user_id, user_id)
    |> assign(:user_name, session["user_name"])
    # Initials are built from first+last (matching <.avatar>); fall back to the
    # display name only for sessions built before that key existed.
    |> assign(:user_initials, session["user_initials"] || name_initials(session["user_name"]))
    |> assign(:user_param, user_param)
    |> assign(:user_avatar, session["user_avatar"])
    |> assign(:user_admin?, session["user_admin?"] == true)
    |> assign_shell_defaults(path)
  end

  # The connected socket, authenticated from the session token. A nil user
  # (missing / revoked / suspended / deactivated token) is the anonymous shell —
  # no subscriptions, no counts, no presence.
  defp mount_authenticated(socket, nil, _session, path) do
    socket
    |> assign(:acting_as, nil)
    |> assign(:acting_as_name, nil)
    |> assign(:acting_as_path, nil)
    |> assign(:user_id, nil)
    |> assign(:user_name, nil)
    |> assign(:user_initials, nil)
    |> assign(:user_param, nil)
    |> assign(:user_avatar, nil)
    |> assign(:user_admin?, false)
    |> assign_shell_defaults(path)
  end

  # Everything the chrome shows is derived from the resolved user (recomputed the
  # same way shell_session/1 builds the curated map), so a replayed curated map
  # can neither render nor subscribe as another member.
  defp mount_authenticated(socket, %User{} = user, session, path) do
    user_id = user.id
    Activity.subscribe(user_id)
    # Re-asked from the cookie session's id against `organization_roles`, never
    # taken from the curated map: the shell is on every page, so a mode it drew
    # from a replayable payload would be the loudest possible lie about whose
    # name the member is writing under (issue #1335).
    acting_as = InitAssigns.acting_as(user, session)

    # The page's own topic, so a message addressed to it moves the badge without
    # a reload. Subscribed to only while really speaking as it — the assign
    # above is the re-authorized answer, not the session's claim.
    Activity.subscribe(acting_as)

    socket
    |> assign(:acting_as, acting_as)
    |> assign(:acting_as_name, acting_as && acting_as.name)
    |> assign(:acting_as_path, acting_as && Organizations.canonical_path(acting_as))
    |> assign(:user_id, user_id)
    |> assign(:user_name, full_name(user))
    |> assign(:user_initials, name_initials(user))
    |> assign(:user_param, Phoenix.Param.to_param(user))
    |> assign(:user_avatar, Vutuv.Avatar.user_url(user, :thumb))
    |> assign(:user_admin?, user.admin?)
    |> assign_shell_defaults(path)
    |> assign(:browser_notifications?, user.browser_notifications?)
    # What `pushManager.subscribe` needs, and nil on an installation whose
    # operator switched push off — which is also what stops the settings card
    # offering a switch that could not work (issue #1729).
    |> assign(:vapid_key, WebPush.public_key())
    # The resolved member themselves, for the browser tab's teaser (issue
    # #1681): it reads their preference and asks their own feed sources what
    # arrived. Nothing renders from it, so it never reaches the client.
    |> assign(:current_user, user)
    |> maybe_start_counts(user, path)
    |> maybe_start_new_members()
    |> maybe_start_presence(user_id, user.show_online_status?)
    |> push_badge()
  end

  # The assigns every render carries, so render/1 never sees a missing key. The
  # badge counts are the most expensive query on every page (an 8-way aggregate
  # for notifications, a COUNT(DISTINCT) join for messages), and the dead render
  # is thrown away the instant the socket connects, so they start at 0
  # (count_badge renders nothing at 0) and are filled in on connect by
  # maybe_start_counts/3. A real unread count appears within a fraction of a
  # second.
  defp assign_shell_defaults(socket, path) do
    socket
    |> assign(:self_online?, false)
    # Whether this member asked for browser notifications (issue #1249). False
    # for the anonymous shell and for the throwaway dead render, which raises
    # none anyway — the real value arrives with the authenticated mount.
    |> assign(:browser_notifications?, false)
    |> assign(:vapid_key, nil)
    # The browser tab's teaser (issue #1681). `tab_hidden?` is what the hook
    # reports and starts false, so nothing is spent on a tab that has not said
    # it is in the background; `teaser` holds the open window, `teaser_quiet_until`
    # the silence after it, and `teaser_filters` this member's compiled content
    # filters once something is actually quoted.
    |> assign(:current_user, nil)
    |> assign(:tab_hidden?, false)
    |> assign(:teaser, nil)
    |> assign(:teaser_quiet_until, nil)
    |> assign(:teaser_filters, nil)
    |> assign(:presence_hidden_ids, MapSet.new())
    |> assign(:messages_count, 0)
    |> assign(:notifications_count, 0)
    |> assign(:brand_path, brand_path(socket.assigns.user_param, path))
    # The current path also drives the active-nav highlight (which top/bottom
    # nav item is the page being viewed). Like brand_path it is the path at
    # mount; every nav destination is reached by a full-reload `href`, so the
    # shell remounts with a fresh path on each of those.
    |> assign(:path, path)
    # Admins get one more figure: how many sign-ups confirmed so far today.
    # Zero renders nothing, so it is also the starting value for everyone else.
    |> assign(:new_members_today, 0)
    # The people total (members here plus the distinct Fediverse accounts
    # following them). Two O(1) atomics reads, so the throwaway dead render can
    # afford it too and a classic controller page shows the figure before its
    # socket connects. Zero (the sub-second before the counter's first reconcile
    # seeds the cell) renders nothing.
    |> assign(:people_count, PeopleCounter.counts())
    # False until the first broadcast: the figure's span is keyed on its value
    # (see .people-total__figure in components.css), so without this gate the
    # first render would look like an insert and every page load would open with
    # the number sliding in.
    |> assign(:people_count_ticked?, false)
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
  defp maybe_start_counts(socket, %User{} = user, path) do
    if connected?(socket) do
      socket
      |> assign(
        # Whichever identity is speaking owns the inbox this badge counts: a
        # publisher who switched into a page is shown the PAGE's unread, the
        # same inbox `/messages` gives them. Notifications stay personal - news
        # about a page has its own list and its own read marker.
        :messages_count,
        initial_count(
          path,
          "/messages",
          socket.assigns.acting_as || user.id,
          &Vutuv.Chat.unread_conversations_count/1
        )
      )
      |> assign(
        # The full struct, so the count skips the read-marker re-read the
        # id-based recount path pays.
        :notifications_count,
        initial_count(path, "/notifications", user, &Activity.unread_notification_count/1)
      )
    else
      socket
    end
  end

  # The admin-only sign-up pulse in the top bar: how many members confirmed
  # their registration since Berlin midnight. Only an admin socket runs the
  # query, so nobody else pays for it. Two feeds keep it true: the
  # `{:people_count, counts}` messages every socket already receives (the member
  # half moves the moment a sign-up confirms) and `Vutuv.DayClock` (Berlin
  # midnight, when the tally starts over) — which only an admin socket
  # subscribes to.
  defp maybe_start_new_members(socket) do
    if connected?(socket) and socket.assigns.user_admin? do
      DayClock.subscribe()
      recount_new_members(socket)
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

  defp initial_count(path, route, subject, counter) do
    # Match the route boundary, not a raw prefix: a profile whose slug merely
    # begins with "messages"/"notifications" (e.g. /messagesanna) must not zero
    # the badge as if the member were sitting on that page.
    if on_route?(path, route), do: 0, else: counter.(subject)
  end

  # True when the current path is `route` or a subpath of it — a route-boundary
  # match, so /messagesanna is not "on" /messages and /jobsy is not "on" /jobs.
  # Drives both the unread-badge zeroing at mount and the active-nav highlight.
  defp on_route?(nil, _route), do: false
  defp on_route?(path, route), do: path == route or String.starts_with?(path, route <> "/")

  # The active nav item (the page being viewed) reads as the current location,
  # not a normal clickable link: brand-tinted, medium weight and no hover
  # affordance. The inactive item keeps the quiet slate link treatment.
  defp nav_link_class(true),
    do:
      "rounded-md px-3 py-2 bg-brand-50 font-semibold text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"

  defp nav_link_class(false),
    do:
      "rounded-md px-3 py-2 text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"

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
  def handle_info({:new_notification, n}, socket),
    do: {:noreply, socket |> recount_notifications() |> push_browser_notification(n)}

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
    do: {:noreply, socket |> recount_messages() |> push_message_notification()}

  def handle_info(:messages_read, socket),
    do: {:noreply, recount_messages(socket)}

  # A new post reached this member's feed (Vutuv.Posts.create_post broadcasts
  # {:new_post, …} to the author *and* every follower). They may be reading
  # another page or another tab, so nudge the TabBadge hook to mark the browser
  # tab. Skip a post the member wrote themselves — their own post must not badge
  # their own tab. The hook only shows the "new posts" dot while the tab is
  # backgrounded and clears it the moment they return, so feed posts (which have
  # no read state) need no server-side unread tally.
  #
  # The dot says *that* something landed; `tab_teaser/3` below says what, for a
  # few seconds, in the tab's own title (issue #1681).
  def handle_info({:new_post, %{author_id: author_id} = payload}, socket) do
    socket =
      if author_id == socket.assigns.user_id do
        socket
      else
        {_result, socket} = tab_teaser(socket, :vutuv, payload[:at])
        push_event(socket, "tab:new_post", %{})
      end

    {:noreply, socket}
  end

  # Something landed through the fediverse (issue #1503): a followed account
  # posted or boosted, or somebody here passed a remote post on. The nudge
  # carries no entry, because whether that write reaches THIS reader depends on
  # their mutes, their follow states, the audience and their language filter —
  # so only their own sources can answer, and that is the lookup the teaser
  # makes anyway. The dot therefore rides on that answer instead of being
  # pushed blind. Every other subscriber of the member topic ignores this event.
  def handle_info({:remote_feed_arrival, %{at: at}}, socket) do
    case tab_teaser(socket, :fediverse, at) do
      {:opened, socket} -> {:noreply, push_event(socket, "tab:new_post", %{})}
      {_other, socket} -> {:noreply, socket}
    end
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

  # The member flipped "Show me browser notifications" (here or in another tab).
  # Their other open tabs learn about it without a reload, the same way the
  # online-status switch reaches them — and a tab that has just been switched ON
  # asks this browser for permission, which is the whole point of the broadcast:
  # the switch is the member's, the permission is each browser's.
  def handle_info({:browser_notifications_pref, enabled?}, socket),
    do: {:noreply, assign(socket, :browser_notifications?, enabled?)}

  # The live people total moved — a sign-up confirmed, an account was deleted,
  # or the counter reconciled one of its two halves against the database. Every
  # socket shows the total, so every socket takes the new figures; only an
  # admin's socket also re-reads today's sign-up tally, and only when the
  # *member* half is what moved: a Fediverse follower arriving says nothing
  # about today's registrations, and the recount is a database query.
  def handle_info({:people_count, counts}, socket) do
    members_moved? = counts.members != socket.assigns.people_count.members

    socket =
      socket
      |> assign(:people_count, counts)
      |> assign(:people_count_ticked?, true)

    {:noreply,
     if(socket.assigns.user_admin? and members_moved?,
       do: recount_new_members(socket),
       else: socket
     )}
  end

  # The `Vutuv.DayClock` tick. This pill counts the **Berlin** day whatever zone
  # the reader is in (it is the operator's own figure), and Berlin midnight is a
  # whole UTC hour, so it still empties exactly then; the clock's other hourly
  # ticks re-ask a question whose answer has not moved, which is the cheap half
  # of letting every reader's own midnight roll their post stamps over.
  def handle_info(:day_changed, socket), do: {:noreply, recount_new_members(socket)}

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
    |> assign(
      :messages_count,
      Vutuv.Chat.unread_conversations_count(socket.assigns.acting_as || socket.assigns.user_id)
    )
    |> push_badge()
  end

  defp recount_notifications(socket) do
    socket
    |> assign(:notifications_count, Activity.unread_notification_count(socket.assigns.user_id))
    |> push_badge()
  end

  defp recount_new_members(socket),
    do: assign(socket, :new_members_today, Dashboard.registrations_today())

  # The pill's accessible name and hover title. It spells out the exact figure,
  # so a compacted "1K" in the pill still names its precise count, and it is
  # what says "today" and "members" — the pill itself is a glyph and a number.
  # `ngettext/4` binds the raw integer to %{count}, hence the %{formatted} one.
  defp new_members_label(count) do
    ngettext(
      "%{formatted} new member today",
      "%{formatted} new members today",
      count,
      formatted: delimited_count(count)
    )
  end

  # The word beside the figure, from `lg` up where the bar has room for it. A
  # glyph and a bare number read as a version string as easily as a head count
  # (reported 2026-08-01), and the accessible name below only ever said so to a
  # screen reader or a hovering mouse.
  #
  # "People" and not "members", because the figure is no longer only members:
  # it is the members here plus the distinct Fediverse accounts following them
  # (see `Vutuv.PeopleCounter`). One word cannot say that, so the word names
  # what both halves have in common and the label below spells the mixture out.
  defp people_total_word(count), do: ngettext("person", "people", count)

  # The pill's **accessible name**, which carries the word at every width —
  # including the phone, where it does not fit on screen. It stays the plain
  # total on purpose: an `aria-label` replaces the element's own text for a
  # screen reader, so the visible "5,950 people" has to be inside it (WCAG
  # 2.5.3), and the breakdown below would push the figure out of it. Whoever
  # wants the composition follows the pill to `/system/members`, which spells
  # it out in ordinary text for everybody.
  #
  # `ngettext/4` binds the raw integer to %{count}, hence the separate
  # %{formatted} placeholder for the grouped figure.
  defp people_total_label(total) do
    ngettext(
      "%{formatted} person",
      "%{formatted} people",
      total,
      formatted: delimited_count(total)
    )
  end

  # The hover title, where the breakdown belongs: a mouse pointer asks "what is
  # this number made of", and the answer does not need to repeat the number the
  # cursor is already sitting on.
  #
  # Two shapes, because the composition is only worth explaining when there is
  # something to explain: an installation nobody follows from the Fediverse
  # (and every intranet installation, where the feature is off) gets the plain
  # total rather than a sentence ending in "plus 0 accounts".
  defp people_total_title(%{fediverse: 0, total: total}), do: people_total_label(total)

  defp people_total_title(%{members: members, fediverse: fediverse}) do
    # Plural on the Fediverse half: that is the number that is genuinely small
    # on a young installation ("plus 1 Fediverse-Account, der folgt"), while
    # the member count reaching 1 means nobody is reading this pill anyway.
    ngettext(
      "%{members} vutuv members plus %{fediverse} Fediverse account that follows them",
      "%{members} vutuv members plus %{fediverse} Fediverse accounts that follow them",
      fediverse,
      members: delimited_count(members),
      fediverse: delimited_count(fediverse)
    )
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

  # -- Browser notifications (issue #1249) ----------------------------------
  #
  # The shell is on every page and already holds this member's activity
  # subscription, so it is the one place that knows something arrived while
  # they were somewhere else. It hands the WebNotify hook a finished line; the
  # hook decides whether the member is actually looking at vutuv and whether
  # this browser granted permission. Two reasons the wording is built here and
  # not in JS: only the server knows the reader's locale, and the page under the
  # bell must not say one thing while the popup says another - hence the shared
  # VutuvWeb.NotificationLine, which owns the destination too.
  #
  # Off unless the member switched it on. That is the whole design of the
  # feature - a popup over whatever somebody is doing is the loudest thing this
  # app can do, so nobody who did not ask is ever prompted, let alone notified.
  # The gate lives in one clause, so a third stream cannot be added without it.
  # "Send a test notification", from the card on /settings/notifications. The
  # status line there can say this browser granted permission and still be
  # wrong about the thing the member actually cares about, because permission
  # is only the last of several links: the socket has to be up, the server has
  # to reach this tab, and the operating system has to draw something. So the
  # test travels the **whole** path a real notification takes rather than being
  # raised locally in JS, which would answer a question nobody asked.
  #
  # Two deliberate exceptions to how every other push behaves. It skips
  # `push_notify/2`'s standing-preference gate, because the member asked for
  # this one by name a moment ago - including, usefully, right after ticking
  # the box and before saving. And it carries `test: true`, which is what lets
  # the hook show it although the member is plainly looking at the page; the
  # away-gate is right for news and would make this button do nothing at all.
  @impl true
  def handle_event("notify:test", _params, %{assigns: %{user_id: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("notify:test", _params, socket) do
    {:noreply,
     push_event(socket, "notify:show", %{
       # Its own tag, so a test never replaces a real notification waiting in
       # the tray - and a second press replaces the first test, not a message.
       tag: "test",
       title: gettext("Test notification"),
       body: gettext("This is what vutuv looks like when something arrives."),
       url: ~p"/settings/notifications",
       test: true
     })}
  end

  # The member clicked a browser notification, so they have seen exactly the
  # event it announced — and nothing else on the bell. Recording it drops that
  # one from the unread tally; the recount then comes back through
  # `:notifications_changed` like every other change, so the badge is never
  # decremented by hand and cannot drift from the feed.
  #
  # Whatever the browser sends is scoped to this socket's member and checked
  # against the kind vocabulary in `Vutuv.Activity`, so the worst a forged
  # payload can do is mark one of the sender's own notifications read.
  def handle_event("notify:seen", %{"kind" => kind, "source_id" => source_id}, socket) do
    Activity.mark_notification_seen(socket.assigns.user_id, kind, source_id)
    {:noreply, socket}
  end

  def handle_event("notify:seen", _params, socket), do: {:noreply, socket}

  # The TabBadge hook reports whether this browser tab is in the background, on
  # connect and on every change. The server needs the answer because the teaser
  # below costs a query: a member sitting in front of the page would pay it for
  # a title they are not reading, and on /feed the source-tab ticker is already
  # saying the same thing beside the tabs.
  #
  # It doubles as the capability handshake the feed's ticker had to add
  # separately (issue #1679): a deploy reloads no open tab, it only reconnects
  # the socket into hours-old markup, and only a bundle carrying this hook can
  # send this event — so an old document simply never teases, rather than being
  # asked whether any of its assets are stale. False until the hook speaks.
  def handle_event("tab:visibility", %{"hidden" => hidden}, socket) do
    {:noreply, assign(socket, :tab_hidden?, hidden == true)}
  end

  ## ── The browser tab's teaser (issue #1681) ──
  #
  # The dot in the tab title says *that* a post arrived. For a few seconds the
  # title says what: the author and the first words, paged through the tab one
  # frame per second, then back to the page's own title. It is the feed's
  # source-tab ticker (#1668) one surface further out, and it obeys the same
  # three rules — one quote per window, the browser owns the clock, a silence
  # after each window — for a fourth reason on top of theirs:
  #
  # **The lookup is the cost, so the window is the budget.** This shell is
  # mounted on every page of every logged-in member and already receives every
  # arrival, so a quote built per arrival would turn one post by a well-followed
  # member into thousands of feed queries in the same instant. Instead a socket
  # spends **one** `Posts.newest_source_entry/3` per window plus cooldown, and
  # everything landing inside that window is counted rather than looked up
  # ("+2 more posts"). The work is then bounded by open tabs, not by how busy
  # the network is.
  #
  # The cooldown is armed on **every** outcome, the refusals included. A quote
  # the reader may not be shown (a muted word, a post their sources do not
  # return) still spent the query, and a lookup that is retried on the very next
  # arrival because it found nothing is exactly the shape that has no rate limit
  # at all — which is worst for the member who muted the word a busy account
  # keeps writing.
  defp tab_teaser(socket, source, at) do
    cond do
      not teasing?(socket) -> {:off, socket}
      window_open?(socket) -> {:counted, count_teaser(socket)}
      quiet?(socket) or is_nil(at) -> {:off, socket}
      true -> open_teaser(socket, source, at)
    end
  end

  # Three cheap refusals before anything is spent: nobody is logged in, the tab
  # is the one being read, or the member switched the teaser off.
  defp teasing?(%{assigns: %{current_user: %User{} = user, tab_hidden?: true}}),
    do: Prefs.get(user, :browser_tab_teaser?)

  defp teasing?(_socket), do: false

  defp window_open?(%{assigns: %{teaser: %{until: until}}}), do: now_ms() < until
  defp window_open?(_socket), do: false

  defp quiet?(%{assigns: %{teaser_quiet_until: until}}) when is_integer(until),
    do: now_ms() < until

  defp quiet?(_socket), do: false

  # `at` is the stamp the arrival will carry in the merged feed, so the sources
  # can be asked for their newest row "at least as new as this". A payload from
  # the release before this one carries none (the blue/green window), and that
  # skips the teaser rather than quoting whatever happens to sit on top.
  defp open_teaser(socket, source, at) do
    {socket, filters} = teaser_filters(socket)
    user = socket.assigns.current_user

    frames =
      case Posts.newest_source_entry(user, source, at) do
        nil -> []
        entry -> entry |> PostTeaser.quote_for(filters, user.id) |> PostTeaser.title_frames()
      end

    push_teaser(socket, frames)
  end

  defp push_teaser(socket, []), do: {:off, arm_quiet(socket, 0)}

  defp push_teaser(socket, frames) do
    id = System.unique_integer([:positive])
    window = length(frames) * @frame_ms

    socket =
      socket
      |> assign(:teaser, %{id: id, count: 1, until: now_ms() + window})
      |> push_event("tab:teaser", %{id: id, frames: frames})
      |> arm_quiet(window)

    {:opened, socket}
  end

  # From the second arrival in the window the quote gives up and becomes a
  # count: two quotes would each stand for less time than it takes to read one,
  # and a queue of ten would hold the title for a minute and a half. The window
  # is not extended by it either, or a busy source would own the tab.
  defp count_teaser(socket) do
    teaser = %{socket.assigns.teaser | count: socket.assigns.teaser.count + 1}

    socket
    |> assign(:teaser, teaser)
    |> push_event("tab:teaser_more", %{id: teaser.id, text: more_line(teaser.count - 1)})
  end

  # `ngettext/3` binds %{count} to the raw integer and a `count:` binding does
  # not override it, so the formatted figure travels under its own name.
  defp more_line(extra) do
    ngettext("+%{formatted} more post", "+%{formatted} more posts", extra,
      formatted: compact_count(extra)
    )
  end

  # Compiled once per socket, and only when a teaser is actually attempted: the
  # vast majority of shells never raise one, and the query would otherwise ride
  # every page load site-wide.
  defp teaser_filters(%{assigns: %{teaser_filters: nil}} = socket) do
    compiled = ContentFilters.compile_for(socket.assigns.current_user)
    {assign(socket, :teaser_filters, compiled), compiled}
  end

  defp teaser_filters(socket), do: {socket, socket.assigns.teaser_filters}

  defp arm_quiet(socket, window_ms),
    do: assign(socket, :teaser_quiet_until, now_ms() + window_ms + teaser_cooldown_ms())

  defp teaser_cooldown_ms,
    do: Application.get_env(:vutuv, :tab_teaser_cooldown_ms, 30_000)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp push_notify(%{assigns: %{browser_notifications?: false}} = socket, _payload), do: socket

  defp push_notify(socket, payload), do: push_event(socket, "notify:show", payload)

  defp push_browser_notification(socket, notification) do
    {title, body} = NotificationLine.title_and_body(notification)

    push_notify(socket, %{
      # What the hook hands back when the popup is clicked, so the bell can
      # drop this one event and keep the rest (`handle_event("notify:seen")`).
      # nil for a kind the tally cannot single out again — the hook then just
      # navigates.
      ack: Activity.dismiss_ref(notification),
      # One tag for the whole activity stream, so a burst of ten likes replaces
      # itself into a single popup instead of stacking ten - and so a member
      # with four vutuv tabs open gets one notification rather than four (the
      # browser collapses same-tag notifications across every page of an
      # origin). A replacement is silent in every browser, so only the first one
      # of a burst makes a sound.
      tag: "activity",
      title: title,
      body: body,
      icon: notification[:actor_avatar],
      # Where the row under the bell would take them - the post, the case, the
      # profile. A popup is raised precisely when the member is NOT looking at
      # vutuv, so the notifications list is the one place that makes them hunt
      # for what they were just told about, and `notification_url/2` owns that
      # fallback for both this and the Web Push payload.
      url: NotificationLine.notification_url(notification, socket.assigns.user_param)
    })
  end

  defp push_message_notification(socket) do
    push_notify(socket, %{
      # Its own tag: a waiting answer and a new like are different errands, and
      # collapsing them into one popup would let a like bury a message.
      tag: "messages",
      # Deliberately no sender and no preview. The broadcast carries neither
      # (Vutuv.Chat sends the conversation id alone), and a direct message is
      # the last thing that should be legible over somebody's shoulder or on a
      # shared screen.
      title: gettext("New message"),
      url: ~p"/messages"
    })
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
      <%!-- "A new version is available" (issue #1729). A deploy reloads
      nothing: an open page keeps the bundle it downloaded, and an installed
      app is reloaded rarer still, so the service worker's `updatefound` is the
      one moment anybody learns. The bar is server-rendered because only the
      server knows the reader's language, and it is shown for logged-out
      visitors too - a stale document is stale whoever is reading it.

      It ships carrying the plain `hidden` attribute and no display utility
      (the issue #880 trap - a utility would out-cascade it). A document from
      the PREVIOUS release meets this markup with the previous release's CSS
      and JS, which is exactly the situation it exists for: that JS never
      unhides it, so the old page shows nothing rather than something
      unstyled. --%>
      <div
        id="sw-update"
        phx-hook="SwUpdate"
        hidden
        class="border-b border-brand-100 bg-brand-50 dark:border-brand-900/60 dark:bg-brand-900/30"
      >
        <div class={[
          "mx-auto flex max-w-6xl flex-wrap items-center gap-x-3 gap-y-2 py-2 text-sm",
          gutter_class()
        ]}>
          <span class="text-slate-700 dark:text-slate-200">
            {gettext("A new version of vutuv is ready.")}
          </span>
          <.button type="button" data-sw-reload class="min-h-10">
            {gettext("Reload")}
          </.button>
        </div>
      </div>
      <div :if={@user_id} id="presence-hook" phx-hook="Presence" phx-update="ignore" class="hidden"></div>
      <%!-- Drives the browser-tab title indicator: prefixes document.title with
      "(N)" for unread messages + notifications and a "•" for new feed posts that
      arrived while the tab was backgrounded (see the TabBadge hook in app.js).
      Fed by push_badge/1 + the {:new_post} handler; phx-update="ignore" because
      the hook owns document.title, not this node. --%>
      <div :if={@user_id} id="tab-badge" phx-hook="TabBadge" phx-update="ignore" class="hidden"></div>
      <%!-- Browser notifications (issue #1249). The hook raises the popups
      ShellLive pushes as "notify:show", and owns the two questions the server
      cannot answer: is this member looking at vutuv right now, and did THIS
      browser grant permission. It is rendered for every logged-in member, on
      or off, so flipping the switch in another tab needs no reload - the
      server simply stops pushing.

      No phx-update="ignore": the prompt below is server-rendered (only the
      server knows the reader's language), so LiveView owns these children and
      the hook re-applies its decision in updated/0.

      The prompt is the answer to "I switched this on at my desk, why is my
      laptop silent?". The switch is the member's and travels with the account;
      the permission belongs to each browser and can only be asked for from a
      real click, which Firefox and Safari refuse to fake on page load. So a
      browser that has never been asked shows one line with the way to say yes.
      It ships carrying the plain `hidden` attribute and no display utility (the
      issue #880 trap - a utility would out-cascade it), and the hook takes it
      off only where it applies: permission still "default", and not dismissed
      in this browser before. --%>
      <%!-- `data-member` and `data-vapid-key` are what the Web Push half in
      app.js reads (issue #1729): who this browser is signed in as, so a
      subscription can be ended when somebody else signs in on the same phone,
      and this installation's own VAPID public key, which
      `pushManager.subscribe` cannot be called without. Both live here rather
      than in the layout because this element is already on every page for
      exactly the members they concern, and empty where push is switched off. --%>
      <div
        :if={@user_id}
        id="web-notify"
        phx-hook="WebNotify"
        data-enabled={to_string(@browser_notifications?)}
        data-member={@user_param}
        data-vapid-key={@vapid_key}
      >
        <div
          :if={@browser_notifications?}
          hidden
          data-notify-prompt
          class="border-b border-brand-100 bg-brand-50 dark:border-brand-900/60 dark:bg-brand-900/30"
        >
          <div class={[
            "mx-auto flex max-w-6xl flex-wrap items-center gap-x-3 gap-y-2 py-2 text-sm",
            gutter_class()
          ]}>
            <span class="text-slate-700 dark:text-slate-200">
              {gettext("You switched browser notifications on. This browser has not been asked for permission yet.")}
            </span>
            <.button type="button" data-notify-allow class="min-h-10">
              {gettext("Allow")}
            </.button>
            <button
              type="button"
              data-notify-dismiss
              class="ml-auto min-h-10 rounded-lg px-3 text-sm font-semibold text-slate-600 hover:bg-brand-100 dark:text-slate-300 dark:hover:bg-brand-900/60"
            >
              {gettext("Not now")}
            </button>
          </div>
        </div>
      </div>
      <%!-- Writing as an organization (issue #1335). The characteristic failure
      of this mode everywhere it exists is somebody posting something personal
      from the brand account, and a discreet badge does not prevent it — so the
      chrome changes unmistakably: a full-width brand bar above the top bar,
      naming the organization, with the way out in it. It sits ABOVE the sticky
      header rather than inside it so the bar's three-track width budget (see
      the design rule) is untouched, and it scrolls away while the header stays,
      which is right: the reminder is loudest where you start writing. --%>
      <div
        :if={@acting_as_name}
        id="acting-as-banner"
        class="bg-brand-700 text-white dark:bg-brand-800"
      >
        <div class={[
          "mx-auto flex max-w-6xl flex-wrap items-center gap-x-3 gap-y-1 py-2 text-sm",
          gutter_class()
        ]}>
          <span class="font-semibold">
            {gettext("You are writing as %{name}.", name: @acting_as_name)}
          </span>
          <%!-- Both controls name `text-white` themselves rather than taking it
          from the bar. `components.css` styles the classic pages with
          `a, button { color: var(--color-brand-600) }`, and a rule on the
          element beats a colour INHERITED from an ancestor — so on this
          brand-700 bar the link and the button came out brand-600 on brand-700,
          which is barely legible. The same trap waits for any control on a
          coloured surface. --%>
          <.link
            navigate={@acting_as_path}
            id="open-acting-as-page"
            class="font-medium text-white underline decoration-white/60 underline-offset-2 hover:decoration-white"
          >
            {gettext("Open the page")}
          </.link>
          <%!-- Leaving is reachable from anywhere the banner is, in one click.
          A CSRF DELETE, never a GET: a link prefetch must not end the mode. --%>
          <.link
            href={~p"/system/act_as"}
            method="delete"
            id="stop-acting-as"
            class="ml-auto inline-flex min-h-10 items-center rounded-lg bg-white/20 px-3 font-semibold text-white hover:bg-white/30"
          >
            {gettext("Write as myself again")}
          </.link>
        </div>
      </div>

      <header class="sticky top-0 z-30 border-b border-slate-200 bg-white/90 backdrop-blur dark:border-slate-800 dark:bg-slate-900/90">
        <%!-- Three tracks, so the member total in the middle one is centred on
        the bar itself rather than on whatever space the flanking content leaves
        over. The side tracks are equal (1fr), so the pill stays put as the nav
        and the icon row change with the viewer and the breakpoint. --%>
        <div class={[
          "mx-auto grid h-16 max-w-6xl grid-cols-[1fr_auto_1fr] items-center gap-4 lg:gap-6",
          gutter_class()
        ]}>
          <div class="flex items-center gap-4 lg:gap-6">
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

            <%!-- `data-nav-bar` + `data-nav-item`: these are plain links, so a
            press here is a full page load that nothing in THIS document ever
            answers. The paint in `app.css` moves the pill on the spot; see the
            press block there. --%>
            <nav
              aria-label={gettext("Main navigation")}
              data-nav-bar
              class="hidden items-center gap-1 text-sm font-medium md:flex"
            >
              <.link
                :if={@user_id}
                href={~p"/feed"}
                data-nav-item
                aria-current={on_route?(@path, "/feed") && "page"}
                class={nav_link_class(on_route?(@path, "/feed"))}
              >
                {gettext("Feed")}
              </.link>
              <%!-- An explicit "Profile" item makes the member's own profile a
                   named, discoverable destination (the logo's deep-link on /feed
                   is too subtle). Only rendered for a logged-in member — it needs
                   @user_param, which only a valid session carries. --%>
              <.link
                :if={@user_id}
                href={~p"/#{@user_param}"}
                data-nav-profile
                data-nav-item
                aria-current={on_route?(@path, "/#{@user_param}") && "page"}
                class={nav_link_class(on_route?(@path, "/#{@user_param}"))}
              >
                {gettext("Profile")}
              </.link>
              <.link
                href={~p"/listings/most_followed_users"}
                data-nav-item
                aria-current={on_route?(@path, "/listings/most_followed_users") && "page"}
                class={nav_link_class(on_route?(@path, "/listings/most_followed_users"))}
              >
                {gettext("Network")}
              </.link>
              <.link
                href={~p"/jobs"}
                data-nav-item
                aria-current={on_route?(@path, "/jobs") && "page"}
                class={nav_link_class(on_route?(@path, "/jobs"))}
              >
                {gettext("Jobs")}
              </.link>
            </nav>
          </div>

          <%!-- The people total, the one figure that belongs to the whole site
          rather than to the viewer, so it sits in the middle of the bar on every
          page: the members here plus the distinct Fediverse accounts that follow
          a member, a page or a topic of this installation, counted once per
          account. It is the exact, grouped number (never a compacted "60K"): it
          ticks up the moment a sign-up confirms or a remote Follow is counted,
          and back down when an account is deleted, live from Vutuv.PeopleCounter
          over PubSub, and a rounded figure would never visibly move. The slot is
          always rendered so the bar keeps its shape while the counter has
          nothing to show, and the pill links to the public member directory —
          the page that answers "who are those people?" and names both halves.

          The visible word rides along for logged-out visitors at every width and
          from `lg` for members (see member_total_word/1); the
          `md:hidden lg:inline-flex` is a fit, not a taste: measured at 768px
          with the German labels, an admin's bar needs 757 of the 736 available
          pixels once this pill joins it (the desktop nav appears at md while
          the width does not grow until lg). Below md the nav is hidden and
          there is ~72px to spare; at lg there is ~219px. So it shows
          everywhere except that one band, where nothing would fit anyway. --%>
          <div id="people-total-slot" class="flex justify-center">
            <.link
              :if={@people_count.total > 0}
              id="people-total"
              href={~p"/system/members"}
              title={people_total_title(@people_count)}
              aria-label={people_total_label(@people_count.total)}
              class="inline-flex items-center gap-1.5 rounded-full px-2 py-1 text-sm font-semibold text-slate-600 hover:bg-slate-100 hover:text-brand-700 sm:px-3 md:hidden lg:inline-flex dark:text-slate-300 dark:hover:bg-slate-800 dark:hover:text-brand-100"
            >
              <.icon_users />
              <%!-- The id carries the value on purpose: LiveView patches text in
                    place and a patched text node animates nothing, so a changed
                    figure has to be a NEW node for the tick to play. --%>
              <span
                id={"people-total-figure-#{@people_count.total}"}
                class={[
                  "people-total__figure tabular-nums",
                  @people_count_ticked? && "people-total__figure--tick"
                ]}
              >
                {delimited_count(@people_count.total)}
              </span>
              <%!-- Gated on who is looking, not on the breakpoint, because that
                    is what the width actually depends on. The documented ~72px
                    of spare room below md was measured with an ADMIN signed in,
                    whose bar also carries search, bookmarks, messages, alerts
                    and an avatar; a logged-out phone bar holds a wordmark, this
                    pill and a Log in button, and measures ~330px free at 606px.
                    So the word shows unconditionally for a visitor — the one who
                    needs it, since they are the one meeting the number for the
                    first time — and waits for `lg` once the bar is carrying a
                    member's controls. Either branch sets at most one display
                    utility, so the #880 two-competing-utilities trap cannot
                    form. --%>
              <span class={@user_id && "hidden lg:inline"}>
                {people_total_word(@people_count.total)}
              </span>
            </.link>
          </div>

          <%!-- `data-nav-bar` here too: these icons are the same kind of plain
          link as the nav above, and pressing one is the same whole new
          document. They inherit that bar's palette, so a press fills the circle
          the way hovering it already tints it. --%>
          <div data-nav-bar class="flex items-center justify-end gap-1">
            <%!-- Admins only: today's confirmed sign-ups (German calendar day),
            live from PeopleCounter and reset by the DayClock at Berlin
            midnight. Rendered only when there is something to report, so a
            quiet day adds no chrome. Links into /admin, where the dashboard
            tile shows the same figure next to yesterday's. --%>
            <.link
              :if={@user_admin? and @new_members_today > 0}
              id="new-members-today"
              href={~p"/admin"}
              title={new_members_label(@new_members_today)}
              aria-label={new_members_label(@new_members_today)}
              class="inline-flex items-center gap-1 rounded-full bg-brand-50 px-3 py-1 text-sm font-semibold text-brand-700 hover:bg-brand-100 dark:bg-brand-900/40 dark:text-brand-100 dark:hover:bg-brand-900/70"
            >
              <.icon_user_plus />
              <span class="tabular-nums">{compact_count(@new_members_today)}</span>
            </.link>

            <.link
              href={~p"/search"}
              data-nav-item
              title={gettext("Search")}
              class="hidden h-10 w-10 items-center justify-center rounded-full text-slate-500 hover:bg-slate-100 sm:flex dark:text-slate-400 dark:hover:bg-slate-800"
            >
              <.icon_search />
            </.link>

            <%= if @user_id do %>
              <.link
                href={~p"/bookmarks"}
                data-nav-item
                title={gettext("Bookmarks")}
                class="hidden h-10 w-10 items-center justify-center rounded-full text-slate-500 hover:bg-slate-100 md:flex dark:text-slate-400 dark:hover:bg-slate-800"
              >
                <.icon_bookmark class="h-6 w-6" />
              </.link>
              <.link
                href={~p"/messages"}
                data-nav-item
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
                data-nav-item
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
      <%!-- The bar is OPAQUE, not the frosted `bg-white/95 backdrop-blur` the
      top bar wears, and that is not a taste decision. A `backdrop-filter` has
      to be re-rasterized against the scrolling content on every frame, and
      that is the path iOS 26 Safari gets wrong on a `position: fixed` element:
      the bar stops following the viewport mid-scroll and hangs in the middle
      of the screen with the feed running on underneath it (reported on an
      iPhone 2026-08-14; the frosted bars of the sites in Apple's own bug
      reports are the tell). Opaque also reads better here — this bar sits over
      dense feed content, where the top bar sits over the page's own top. --%>
      <%!-- Safe areas (issue #1464). The bar is 4rem of tabs PLUS whatever the
      device reserves below them: on a phone with a home indicator that strip
      is not tappable, so a bar that ends at the viewport edge puts its labels
      under it. It grows by the inset and pads the same amount away, which
      leaves the tabs their full 4rem — and `<main>`/the footer reserve the
      same total, so nothing scrolls underneath. The 0.75rem side padding is
      what the report asked for: the outer two tabs sat hard against the screen
      edges, and in landscape the sensor housing covers that edge outright. --%>
      <nav
        aria-label={gettext("Main navigation")}
        data-nav-bar="tabs"
        class={[
          "fixed inset-x-0 bottom-0 z-30 grid border-t border-slate-200 bg-white md:hidden dark:border-slate-800 dark:bg-slate-900",
          "h-[calc(4rem+env(safe-area-inset-bottom))] pb-[env(safe-area-inset-bottom)]",
          "pl-[max(0.75rem,env(safe-area-inset-left))] pr-[max(0.75rem,env(safe-area-inset-right))]",
          if(@user_id, do: "grid-cols-5", else: "grid-cols-2")
        ]}
      >
        <%= if @user_id do %>
          <%!-- On /feed this tab points at the page under the reader's thumb, so
          once they are a screen down it scrolls back to the top instead of
          reloading (`scroll_top`; `assets/js/scroll_top_tab.js` takes the
          press). The arrow is the promise that it will: a control that behaves
          differently has to look different first, or the press reads as a
          reload. --%>
          <.tab href={~p"/feed"} label={gettext("Feed")} active={on_route?(@path, "/feed")} scroll_top>
            <.icon_feed data-tab-icon="feed" />
            <.icon_scroll_top />
          </.tab>
        <% end %>
        <.tab href={~p"/search"} label={gettext("Search")} active={on_route?(@path, "/search")}><.icon_search /></.tab>
        <%= if @user_id do %>
          <.tab href={~p"/messages"} label={gettext("Messages")} count={@messages_count} active={on_route?(@path, "/messages")}><.icon_envelope /></.tab>
          <.tab href={~p"/notifications"} label={gettext("Alerts")} count={@notifications_count} active={on_route?(@path, "/notifications")}><.icon_bell /></.tab>
          <%!-- The member's own avatar is the Profile tab — the universal mobile
          convention for "you", so the profile is reachable on phones too, not
          just via the desktop nav or the logo's /feed deep-link. --%>
          <.tab href={~p"/#{@user_param}"} label={gettext("Profile")} data-mobile-profile active={on_route?(@path, "/#{@user_param}")}>
            <%= if @user_avatar do %>
              <img src={@user_avatar} alt="" class="h-6 w-6 rounded-full object-cover" />
            <% else %>
              <span class="flex h-6 w-6 items-center justify-center rounded-full bg-brand-700 text-[10px] font-bold text-white">
                {@user_initials}
              </span>
            <% end %>
          </.tab>
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
  attr(:active, :boolean, default: false)
  attr(:scroll_top, :boolean, default: false)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  defp tab(assigns) do
    ~H"""
    <%!-- The weight lives on the link, not on the label span: the press paint
    in `app.css` has one element to work on, and the label inherits it. Two
    owners of the same property is what leaves a half-repainted control. --%>
    <.link
      href={@href}
      data-nav-item
      data-scroll-top={(@active && @scroll_top) || nil}
      aria-current={@active && "page"}
      class={[
        "flex flex-col items-center justify-center gap-0.5",
        if(@active,
          do: "font-semibold text-brand-600 dark:text-brand-300",
          else: "text-slate-600 dark:text-slate-400"
        )
      ]}
      {@rest}
    >
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

  # A small group of people: the "members" glyph on the site-wide member total.
  defp icon_users(assigns) do
    ~H"""
    <svg class="h-5 w-5" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d="M15 19.128a9.38 9.38 0 0 0 2.625.372 9.337 9.337 0 0 0 4.121-.952 4.125 4.125 0 0 0-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 0 1 8.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0 1 11.964-3.07M12 6.375a3.375 3.375 0 1 1-6.75 0 3.375 3.375 0 0 1 6.75 0Zm8.25 2.25a2.625 2.625 0 1 1-5.25 0 2.625 2.625 0 0 1 5.25 0Z" />
    </svg>
    """
  end

  # A person with a plus: the "new member" glyph on the admin sign-up pill.
  defp icon_user_plus(assigns) do
    ~H"""
    <svg class="h-5 w-5" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d="M18 7.5v3m0 0v3m0-3h3m-3 0h-3m-2.25-4.125a3.375 3.375 0 1 1-6.75 0 3.375 3.375 0 0 1 6.75 0ZM3 19.235v-.11a6.375 6.375 0 0 1 12.75 0v.109A12.318 12.318 0 0 1 9.374 21c-2.331 0-4.512-.645-6.374-1.766Z" />
    </svg>
    """
  end

  attr(:rest, :global)

  defp icon_feed(assigns) do
    ~H"""
    <svg
      class="h-6 w-6"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
      {@rest}
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M12 7.5h1.5m-1.5 3h1.5m-7.5 3h7.5m-7.5 3h7.5m3-9h3.375c.621 0 1.125.504 1.125 1.125V18a2.25 2.25 0 0 1-2.25 2.25M16.5 7.5V18a2.25 2.25 0 0 0 2.25 2.25M16.5 7.5V4.875c0-.621-.504-1.125-1.125-1.125H4.125C3.504 3.75 3 4.254 3 4.875V18a2.25 2.25 0 0 0 2.25 2.25h13.5M6 7.5h3v3H6v-3Z"
      />
    </svg>
    """
  end

  # The Feed tab's second face, drawn in place of the glyph above once the feed
  # is a screen down (the rule lives in `components.css`).
  #
  # It rests on an inline `display: none`, and that is a deploy decision rather
  # than a style one. A deploy reloads nothing: an open phone keeps the previous
  # release's stylesheet and the reconnecting socket patches this markup into
  # it, so an arrow whose only "off" switch were a rule in the NEW stylesheet
  # would sit beside the feed glyph, two icons crowding one tab, until the
  # reader happened to reload — the shape the feed's tab ticker shipped in
  # v7.347.0. Inline styles ship with the markup, so the old stylesheet needs to
  # know nothing.
  #
  # Why not the `hidden` attribute, which reads better: Tailwind's preflight
  # spells it `display: none !important` inside `@layer base`, and an important
  # declaration in a layer beats an important one outside every layer — the
  # cascade reverses layer order for important declarations and puts unlayered
  # last. So `hidden` here cannot be lifted by any author rule at all; measured
  # in a browser, the arrow simply never appeared. An inline style is an
  # ordinary declaration and yields to the one `!important` rule in
  # `components.css`. Nothing here carries a Tailwind display utility either
  # (it would out-cascade the inline style, the issue #880 trap).
  defp icon_scroll_top(assigns) do
    ~H"""
    <svg
      style="display: none"
      data-tab-icon="top"
      class="h-6 w-6"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <path stroke-linecap="round" stroke-linejoin="round" d="M4.5 10.5 12 3m0 0 7.5 7.5M12 3v18" />
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
