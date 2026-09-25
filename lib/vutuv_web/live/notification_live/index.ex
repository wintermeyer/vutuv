defmodule VutuvWeb.NotificationLive.Index do
  @moduledoc """
  The notifications page: one timeline of what happened, with every look the
  member took at it drawn as a line (2026-09 rebuild, replacing the filter
  chips, the reply inbox and the post cards grouped by subject).

  ## Why lines

  A member who looked at 14:00, had no time to act and came back at 18:00
  used to find everything marked read: the one read marker
  (`users.notifications_read_at`) moves on every look, so it cannot say what
  was already on screen at 14:00. Each look is now a row of its own
  (`Vutuv.Activity.record_notification_visit/2`, written on the connected
  mount here and when the bell's preview closes), and
  `VutuvWeb.NotificationLive.Timeline` draws them between the events: what
  arrived after the last look sits above its line and is marked new.

  ## Time travel

    * `?at=<visit>` shows the list as it stood at that look: nothing newer,
      and "new" measured from the look before it.
    * `?day=<date>` opens a day (and the one before it, so a morning is never
      a near-empty page). The month calendar is the feed's
      (`VutuvWeb.PostLive.FeedCalendar`), shaded by
      `Vutuv.Activity.notification_counts_by_day/2`.

  Without either the page shows today and yesterday and takes live arrivals.

  ## Rows

  Replies, thread answers, mentions and replies from other networks are the
  feed's own cards (`post_card/1`, `remote_reply_card/1`), headed by what they
  answer and followed by the member's own answer. The card's Reply opens the
  composer under it (the `InlineReply` hook; without JavaScript the link still
  leads to the reply page). Likes of one post are one line, new people one
  line, everything rarer one line each. "Only replies and mentions" (a switch
  kept with the member, `users.notifications_replies_only?`)
  keeps the cards alone.

  The static render carries the whole list (issue #919); the visit is only
  recorded, and the read marker only moved, once the socket connects.
  """
  use VutuvWeb, :live_view

  import VutuvWeb.FediverseComponents, only: [remote_actor_link: 3]
  import VutuvWeb.PostComponents, only: [post_card: 1, remote_reply_card: 1]
  import VutuvWeb.PostLive.FeedCalendar

  import VutuvWeb.NotificationLine,
    only: [
      cv_entry_label: 1,
      cv_entry_path: 2,
      kind_classes: 1,
      kind_glyph: 1,
      kind_label: 1,
      actor_target: 1,
      notification_target: 2,
      notification_text: 1
    ]

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})
  on_mount(VutuvWeb.Live.RemoteCounts)

  alias Vutuv.Accounts
  alias Vutuv.Activity
  alias Vutuv.Activity.ReplyStatus
  alias Vutuv.Fediverse
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.ViewerClock
  alias VutuvWeb.Live.FeedTimeTravel
  alias VutuvWeb.Live.MountHandoff
  alias VutuvWeb.Live.RemoteReplyActions
  alias VutuvWeb.NotificationLive.Timeline
  alias VutuvWeb.PostTeaser

  # One window (two days) reads at most this many events; a busier one offers
  # "Load more" inside the window.
  @window_limit 300

  # How many of a handle change's rewritten posts are named.
  @change_preview_limit 5

  # How many faces a reactions line shows before "+N".
  @stack_faces 5

  # A live arrival rebuilds the page; several in a burst rebuild it once.
  @reload_delay 1_000

  # What the static render hands the connected mount (`load_first/1`).
  @payload_keys [:upper, :top_day, :cursor, :entries, :visits, :cards]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # "New" is measured from the look before this sitting (a reload or a
    # reconnect inside it must not swallow what the first look marked new),
    # and from the read marker for a member who has no looks recorded yet.
    new_since = Activity.previous_notification_visit(user.id) || user.notifications_read_at

    if connected?(socket) do
      Activity.subscribe(user.id)
      Activity.mark_notifications_read(user.id)
      Activity.record_notification_visit(user.id, "page")
      Vutuv.DayClock.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Notifications"))
     |> assign(:new_since, new_since)
     |> assign(:dismissed, Activity.dismissed_event_ids(user.id))
     |> assign(:today, ViewerClock.today())
     |> assign(:composing, nil)
     |> assign(:reload_scheduled?, false)
     |> assign(:cal_open?, false)
     |> assign(:cal_counts, %{})
     |> assign(:cal_counted, nil)
     |> assign(:cal_capped?, false)
     |> assign(:replies_only?, user.notifications_replies_only?)
     |> assign(:travel, nil)
     |> assign(:day, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    travel = parse_at(params["at"])
    day = if travel, do: ViewerClock.date(travel), else: parse_day(params["day"])

    same_window? =
      Map.has_key?(socket.assigns, :blocks) and
        {travel, day} == {socket.assigns.travel, socket.assigns.day}

    socket =
      socket
      |> assign(:travel, travel)
      |> assign(:day, day)
      |> assign(:cal_month, FeedTimeTravel.month_of(day))

    # A patch that keeps the window rebuilds from what is loaded; a new one loads.
    socket = if same_window?, do: rebuild(socket), else: load_first(socket)

    {:noreply, load_calendar_counts(socket)}
  end

  # ── Events ──

  # The card's Reply, caught by the `InlineReply` hook: the composer opens
  # under the card, and a second press folds it away.
  @impl true
  def handle_event("compose", %{"id" => id}, socket) do
    {:noreply, assign(socket, :composing, if(socket.assigns.composing == id, do: nil, else: id))}
  end

  # The switch is the member's setting: written at once, and the list is
  # filtered from what is already loaded.
  def handle_event("toggle-replies-only", _params, socket) do
    on? = !socket.assigns.replies_only?
    Accounts.set_notifications_replies_only(socket.assigns.current_user, on?)
    {:noreply, socket |> assign(:replies_only?, on?) |> rebuild()}
  end

  def handle_event("cancel-compose", _params, socket),
    do: {:noreply, assign(socket, :composing, nil)}

  def handle_event("load-more", _params, socket) do
    {:noreply, load_next_page(socket)}
  end

  # A new follower's Follow back, without a reload.
  def handle_event("follow", %{"followee" => followee_id}, socket) do
    Social.follow(socket.assigns.current_user, followee_id)
    {:noreply, load(socket)}
  end

  # The ⋯ menu of a reply from another network offers Report to its reader.
  def handle_event("report-remote-reply", %{"id" => id}, socket) do
    RemoteReplyActions.report(socket, id, &load/1)
  end

  # The calendar's controls (`VutuvWeb.PostLive.FeedCalendar`).
  def handle_event("cal-toggle", _params, socket) do
    {:noreply, socket |> update(:cal_open?, &(!&1)) |> load_calendar_counts()}
  end

  def handle_event("cal-month", %{"n" => n}, socket) do
    case Integer.parse(to_string(n)) do
      {n, ""} ->
        {:noreply,
         socket
         |> update(:cal_month, &FeedTimeTravel.shift_month(&1, n))
         |> load_calendar_counts()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cal-day", %{"date" => date}, socket) do
    case parse_day(date) do
      nil -> {:noreply, socket}
      day -> {:noreply, push_patch(socket, to: page_path(socket.assigns, day: day, at: nil))}
    end
  end

  def handle_event("travel-now", _params, socket),
    do: {:noreply, push_patch(socket, to: page_path(socket.assigns, day: nil, at: nil))}

  # ── Messages ──

  # An event that interrupts nobody (a throttled like, anything on a muted
  # post) still belongs on this page.
  @impl true
  def handle_info({:quiet_notification, notification}, socket),
    do: handle_info({:new_notification, notification}, socket)

  # The member is watching it arrive, so it is read: the marker moves once the
  # burst is in, and the shell's badge stays at zero. Only the live present
  # shows arrivals; a day or a look in the past is a fixed window.
  def handle_info({:new_notification, _notification}, socket) do
    if socket.assigns.reload_scheduled? do
      {:noreply, socket}
    else
      Process.send_after(self(), :reload, @reload_delay)
      {:noreply, assign(socket, :reload_scheduled?, true)}
    end
  end

  def handle_info(:reload, socket) do
    Activity.mark_notifications_read(socket.assigns.current_user.id)
    socket = assign(socket, :reload_scheduled?, false)
    {:noreply, if(present?(socket.assigns), do: load(socket), else: socket)}
  end

  # An answer written under a card: fold the composer and show the answer.
  def handle_info({:composer_answered, _id, _post}, socket) do
    {:noreply, socket |> assign(:composing, nil) |> load()}
  end

  # Midnight in the reader's zone (`Vutuv.DayClock` ticks hourly): the present
  # moves on to a new day; a day or a look in the past only relabels.
  def handle_info(:day_changed, socket) do
    today = ViewerClock.today()

    cond do
      today == socket.assigns.today -> {:noreply, socket}
      present?(socket.assigns) -> {:noreply, socket |> assign(:today, today) |> load()}
      true -> {:noreply, assign(socket, :today, today)}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ── Loading ──

  defp present?(assigns), do: is_nil(assigns.travel) and is_nil(assigns.day)

  # The first load of a window runs twice per visit, once for the static render
  # and once on connect, moments apart: the static pass stashes what it read
  # and the connected one takes it (`VutuvWeb.Live.MountHandoff`). Any miss
  # (expired, a patch, a reconnect) simply loads.
  defp load_first(socket) do
    viewer_id = socket.assigns.current_user.id
    subject = {:notifications, socket.assigns.day, socket.assigns.travel}

    if connected?(socket) do
      case MountHandoff.take(viewer_id, subject) do
        {:ok, payload} -> socket |> assign(payload) |> rebuild()
        :error -> load(socket)
      end
    else
      socket = load(socket)
      MountHandoff.stash(viewer_id, subject, Map.take(socket.assigns, @payload_keys))
      socket
    end
  end

  # The window the page shows: the chosen day (today by default) and the day
  # before it, cut at the look being travelled to, or at now.
  defp window(assigns) do
    top_day = assigns.day || ViewerClock.today()
    {from, _} = ViewerClock.day_window(Date.add(top_day, -1))
    {_, day_end} = ViewerClock.day_window(top_day)
    upper = assigns.travel || Enum.min([day_end, NaiveDateTime.utc_now(:second)], NaiveDateTime)
    {from, upper, top_day, day_end}
  end

  defp load(socket) do
    user = socket.assigns.current_user
    {from, upper, top_day, day_end} = window(socket.assigns)

    page =
      Activity.notifications_page(user.id,
        limit: @window_limit,
        cursor: %{at: upper, ids: [], since: from}
      )

    entries = prepare(page.entries, socket.assigns)

    # One read of the looks for the whole window, the rail's day included.
    # The sitting the member is in is "now", not one of them.
    visits =
      user.id |> Activity.notification_visits(from, day_end) |> earlier_looks(socket.assigns)

    socket
    |> assign(:upper, upper)
    |> assign(:top_day, top_day)
    |> assign(:cursor, page.more? && page.next_cursor)
    |> assign(:entries, entries)
    |> assign(:visits, visits)
    |> assign(:cards, cards(entries, user))
    |> rebuild()
  end

  defp load_next_page(%{assigns: %{cursor: nil}} = socket), do: socket

  defp load_next_page(socket) do
    user = socket.assigns.current_user

    page =
      Activity.notifications_page(user.id, limit: @window_limit, cursor: socket.assigns.cursor)

    entries = prepare(page.entries, socket.assigns)

    socket
    |> assign(:cursor, page.more? && page.next_cursor)
    |> update(:entries, &(&1 ++ entries))
    |> update(:cards, &merge_cards(&1, cards(entries, user)))
    |> rebuild()
  end

  # Read state (dismissed in the shell, engaged with in the feed) and what the
  # member did about each reply.
  defp prepare(entries, assigns) do
    user = assigns.current_user

    entries
    |> then(&Activity.with_seen_flags(user.id, &1, assigns.dismissed))
    |> then(&ReplyStatus.put(user, &1))
  end

  # The blocks from what is loaded, with no reads: the switch costs nothing
  # but the grouping.
  defp rebuild(socket) do
    %{upper: upper, travel: travel, top_day: top_day, visits: visits} = socket.assigns

    # The look being travelled to is the top of the page, not a line on it.
    lines = Enum.filter(visits, &(NaiveDateTime.compare(&1.at, upper) == :lt))

    blocks =
      Timeline.build(socket.assigns.entries, lines,
        new_since: if(travel, do: last_at(lines), else: socket.assigns.new_since),
        replies_only?: socket.assigns.replies_only?
      )

    socket
    |> assign(:blocks, blocks)
    |> assign(:empty?, not Enum.any?(blocks, &match?({:row, _}, &1)))
    |> assign(:day_visits, Enum.filter(visits, &(ViewerClock.date(&1.at) == top_day)))
    |> assign_paths()
  end

  defp last_at([]), do: nil
  defp last_at(visits), do: List.last(visits).at

  defp earlier_looks(visits, %{new_since: nil}), do: visits

  defp earlier_looks(visits, %{new_since: since}),
    do: Enum.filter(visits, &(NaiveDateTime.compare(&1.at, since) != :gt))

  # The calendar's shading: only once the socket is up and the grid is open,
  # and once per month it is paged to.
  defp load_calendar_counts(%{assigns: %{cal_open?: true, cal_month: month}} = socket) do
    if connected?(socket) and socket.assigns.cal_counted != month do
      {counts, capped?} =
        Activity.notification_counts_by_day(socket.assigns.current_user.id, month)

      socket
      |> assign(:cal_counts, counts)
      |> assign(:cal_capped?, capped?)
      |> assign(:cal_counted, month)
    else
      socket
    end
  end

  defp load_calendar_counts(socket), do: socket

  # Everything the rows draw beyond the events themselves, in a handful of
  # batched reads: the posts a card shows and the posts a line names, their
  # counts, the replies from other networks and what the member did to them.
  # Built per loaded page and merged, so "Load more" reads only its own rows.
  defp cards(entries, viewer) do
    card_ids = entries |> Enum.map(&card_post_id/1) |> Enum.reject(&is_nil/1)

    named_ids =
      Enum.flat_map(entries, &[&1[:post_id], &1[:root_post_id] | List.wrap(&1[:post_ids])])

    answers = for %{answer: %Post{} = post} <- entries, do: post.id

    posts = Posts.visible_posts_by_ids(viewer, card_ids ++ named_ids ++ answers)

    card_posts =
      card_ids
      |> Enum.map(&Map.get(posts, &1))
      |> Enum.reject(&is_nil/1)
      |> Repo.preload(Posts.render_preloads())
      |> Map.new(&{&1.id, &1})

    notes =
      for(%{kind: "fediverse_reply"} = item <- entries, do: item[:note_id])
      |> Fediverse.get_notes()

    marks = Fediverse.mark_lookup(Map.values(notes), viewer)

    %{
      posts: posts,
      card_posts: card_posts,
      engagement: Posts.post_engagement_map(Map.keys(card_posts), viewer),
      notes: notes,
      marks: Map.new(notes, fn {id, note} -> {id, marks.(note)} end)
    }
  end

  defp merge_cards(old, new), do: Map.merge(old, new, fn _key, a, b -> Map.merge(a, b) end)

  # The post a words row shows as its card.
  defp card_post_id(%{kind: kind} = item) when kind in ~w(reply thread), do: item[:reply_post_id]
  defp card_post_id(%{kind: "mention"} = item), do: item[:post_id]
  defp card_post_id(_item), do: nil

  # The post a words row answers: the member's own post, or a thread's root.
  defp subject_post_id(%{kind: "thread"} = item), do: item[:root_post_id]

  defp subject_post_id(%{kind: kind} = item) when kind in ~w(reply fediverse_reply),
    do: item[:post_id]

  defp subject_post_id(_item), do: nil

  # ── URLs ──

  defp page_path(assigns, overrides) do
    day = Keyword.get(overrides, :day, assigns.day)
    at = Keyword.get(overrides, :at, assigns.travel)

    query =
      [
        at: at && NaiveDateTime.to_iso8601(at),
        day: is_nil(at) && day && Date.to_iso8601(day)
      ]
      |> Enum.filter(fn {_key, value} -> value end)

    if query == [], do: ~p"/notifications", else: ~p"/notifications?#{query}"
  end

  defp parse_at(value) when is_binary(value) do
    with {:ok, at} <- NaiveDateTime.from_iso8601(value),
         :lt <- NaiveDateTime.compare(at, NaiveDateTime.utc_now()) do
      NaiveDateTime.truncate(at, :second)
    else
      _ -> nil
    end
  end

  defp parse_at(_value), do: nil

  defp parse_day(value) do
    case FeedTimeTravel.parse_date(value) do
      {:ok, date} -> if FeedTimeTravel.reachable?(date), do: date
      :error -> nil
    end
  end

  # ── Render ──

  @impl true
  def render(assigns) do
    ~H"""
    <div id="notifications" class="py-6 md:py-8">
      <div class="grid gap-6 md:grid-cols-3">
        <div class="min-w-0 md:col-span-2">
          <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
            <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">
              {gettext("Notifications")}
            </h1>
            <button
              type="button"
              id="replies-only"
              phx-click="toggle-replies-only"
              role="switch"
              aria-checked={to_string(@replies_only?)}
              class="inline-flex min-h-10 items-center gap-2.5 text-sm font-medium text-slate-700 dark:text-slate-300"
            >
              <span class={[
                "relative h-6 w-10 shrink-0 rounded-full transition-colors",
                if(@replies_only?, do: "bg-brand-600", else: "bg-slate-300 dark:bg-slate-600")
              ]}>
                <span class={[
                  "absolute left-0.5 top-0.5 h-5 w-5 rounded-full bg-white shadow transition-transform",
                  @replies_only? && "translate-x-4"
                ]}></span>
              </span>
              {gettext("Only replies and mentions")}
            </button>
          </div>

          <%!-- The phone has no rail column: the calendar and the looks of the
          day sit above the list, folded. --%>
          <div class="mt-4 md:hidden">
            <.time_travel
              id="phone"
              cal_open?={@cal_open?}
              cal_month={@cal_month}
              cal_counts={@cal_counts}
              cal_capped?={@cal_capped?}
              day={@day}
              today={@today}
              top_day={@top_day}
              looks={@paths.looks}
              now_path={@paths.now}
              now?={@paths.now?}
            />
          </div>

          <div
            :if={@travel}
            id="travel-banner"
            class="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900 ring-1 ring-amber-300 dark:bg-amber-950/40 dark:text-amber-100 dark:ring-amber-700/60"
          >
            <p class="mb-0 min-w-0 flex-1">
              <strong>{gettext("As of %{time}.", time: ViewerClock.format(@travel, :time))}</strong>
              {gettext("This is the list as it stood when you were here. Everything that came later is hidden.")}
            </p>
            <.link
              patch={@paths.now}
              class="inline-flex h-9 items-center rounded-lg bg-amber-600 px-3 text-sm font-semibold text-white hover:bg-amber-700"
            >
              {gettext("Back to now")}
            </.link>
          </div>

          <div id="notification-timeline">
            <.block
              :for={block <- @blocks}
              block={block}
              current_user={@current_user}
              cards={@cards}
              composing={@composing}
              socket={@socket}
            />
          </div>

          <p :if={@empty?} class="mt-6 text-slate-600 dark:text-slate-400">
            {gettext("Nothing happened in these two days.")}
          </p>

          <.load_more :if={@cursor} class="mt-6" />

          <div class="mt-6 flex justify-center">
            <.link
              id="earlier-days"
              patch={@paths.earlier}
              class="inline-flex min-h-10 items-center rounded-xl px-4 text-sm font-semibold text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50 dark:text-slate-200 dark:ring-slate-700 dark:hover:bg-slate-800"
            >
              {gettext("Earlier days")}
            </.link>
          </div>
        </div>

        <aside class="hidden min-w-0 md:block">
          <.time_travel
            id="desktop"
            cal_open?={@cal_open?}
            cal_month={@cal_month}
            cal_counts={@cal_counts}
            cal_capped?={@cal_capped?}
            day={@day}
            today={@today}
            top_day={@top_day}
            looks={@paths.looks}
            now_path={@paths.now}
            now?={@paths.now?}
          />
        </aside>
      </div>
    </div>
    """
  end

  # Every link the page draws, built once per rebuild with the page's own URL
  # rule, so the template reads plain assigns: a function handed `assigns` in
  # the template would switch change tracking off for everything it feeds.
  defp assign_paths(socket) do
    a = socket.assigns

    assign(socket, :paths, %{
      now: page_path(a, day: nil, at: nil),
      now?: present?(a),
      earlier: page_path(a, day: Date.add(a.top_day, -2), at: nil),
      looks:
        a.day_visits
        |> Enum.reverse()
        |> Enum.map(&%{visit: &1, path: page_path(a, at: &1.at), current?: a.travel == &1.at})
    })
  end

  # The calendar and the looks of the shown day.
  attr(:id, :string, required: true)
  attr(:cal_open?, :boolean, required: true)
  attr(:cal_month, :any, required: true)
  attr(:cal_counts, :map, required: true)
  attr(:cal_capped?, :boolean, required: true)
  attr(:day, :any, required: true)
  attr(:today, :any, required: true)
  attr(:top_day, :any, required: true)
  attr(:looks, :list, required: true)
  attr(:now_path, :string, required: true)
  attr(:now?, :boolean, required: true)

  defp time_travel(assigns) do
    ~H"""
    <div class="space-y-3">
      <.feed_calendar
        id={"notification-calendar-#{@id}"}
        open?={@cal_open?}
        month={@cal_month}
        day={@day}
        today={@today}
        metric="notifications"
        switch?={false}
        counts={@cal_counts}
        capped?={@cal_capped?}
      />

      <section
        id={"visits-#{@id}"}
        class="rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800"
      >
        <h2 class="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
          {gettext("Your visits on %{day}", day: ViewerClock.format(@top_day, :day_month))}
        </h2>
        <ul class="space-y-1">
          <li :if={@top_day == @today}>
            <.link patch={@now_path} aria-current={@now? && "true"} class={visit_class(@now?)}>
              <span class="w-12 font-bold tabular-nums text-accent">
                {ViewerClock.format(NaiveDateTime.utc_now(:second), :time)}
              </span>
              <span class="text-sm text-slate-500 dark:text-slate-400">
                {pgettext("visit list", "now")}
              </span>
            </.link>
          </li>
          <li :for={look <- @looks}>
            <.link
              patch={look.path}
              aria-current={look.current? && "true"}
              data-visit={NaiveDateTime.to_iso8601(look.visit.at)}
              class={visit_class(look.current?)}
            >
              <span class="w-12 font-bold tabular-nums">{ViewerClock.format(look.visit.at, :time)}</span>
              <span class="text-sm text-slate-500 dark:text-slate-400">{visit_source(look.visit)}</span>
            </.link>
          </li>
        </ul>
        <p
          :if={@looks == [] and @top_day != @today}
          class="mb-0 text-sm text-slate-500 dark:text-slate-400"
        >
          {gettext("You were not here on this day.")}
        </p>
        <p class="mb-0 mt-2 text-xs text-slate-500 dark:text-slate-400">
          {gettext("A visit shows the list as it stood at that moment.")}
        </p>
      </section>
    </div>
    """
  end

  defp visit_class(true),
    do:
      "flex min-h-10 items-center gap-3 rounded-lg bg-brand-50 px-2 text-brand-800 dark:bg-brand-800/60 dark:text-brand-200"

  defp visit_class(false),
    do:
      "flex min-h-10 items-center gap-3 rounded-lg px-2 text-slate-800 hover:bg-slate-50 dark:text-slate-100 dark:hover:bg-slate-800"

  defp visit_source(%{source: "bell"}), do: gettext("via the bell")
  defp visit_source(_visit), do: gettext("opened the page")

  # ── Blocks ──

  attr(:block, :any, required: true)
  attr(:current_user, :any, required: true)
  attr(:cards, :map, required: true)
  attr(:composing, :any, required: true)
  attr(:socket, :any, required: true)

  defp block(%{block: {:day, day}} = assigns) do
    assigns = assign(assigns, :day, day)

    ~H"""
    <h2
      data-day-heading
      class="mb-2 mt-6 text-sm font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400"
    >
      {day_label(@day)}
    </h2>
    """
  end

  defp block(%{block: {:fresh, count, since}} = assigns) do
    assigns = assign(assigns, count: count, since: since)

    ~H"""
    <div data-fresh-line class="my-3 flex items-center gap-3 text-xs font-semibold text-accent">
      <span class="h-px flex-1 bg-accent/60" aria-hidden="true"></span>
      {fresh_label(@count, @since)}
      <span class="h-px flex-1 bg-accent/60" aria-hidden="true"></span>
    </div>
    """
  end

  defp block(%{block: {:visits, visits}} = assigns) do
    assigns = assign(assigns, :visits, visits)

    ~H"""
    <div
      data-visit-line
      class="my-3 flex items-center gap-3 text-xs font-semibold text-slate-500 dark:text-slate-400"
    >
      <span class="h-0.5 flex-1 rounded bg-slate-300 dark:bg-slate-700" aria-hidden="true"></span>
      <span>
        {gettext("You were here · %{time}",
          time: Enum.map_join(@visits, ", ", &ViewerClock.format(&1.at, :time))
        )}
        <span :if={match?([%{source: "bell"}], @visits)} class="font-normal">
          {gettext("via the bell")}
        </span>
      </span>
      <span class="h-0.5 flex-1 rounded bg-slate-300 dark:bg-slate-700" aria-hidden="true"></span>
    </div>
    """
  end

  defp block(%{block: {:row, row}} = assigns) do
    assigns = assign(assigns, :row, row)

    ~H"""
    <article
      id={"row-#{@row.id}"}
      data-row={@row.type}
      data-kind={@row[:item] && @row.item.kind}
      data-fresh={@row.fresh? && "true"}
      phx-hook={@row.type == :words && "InlineReply"}
      data-row-id={@row.id}
      class={[
        "relative mb-2 rounded-2xl bg-white shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800",
        @row.type == :words && "px-4 pb-2 pt-3 sm:px-5",
        @row.type != :words && "flex gap-3 px-4 py-3 sm:px-5",
        @row.fresh? && "bg-brand-50/60 ring-brand-200 dark:bg-brand-800/25 dark:ring-brand-800"
      ]}
    >
      <span
        :if={@row.fresh?}
        class="absolute left-1.5 top-5 h-1.5 w-1.5 rounded-full bg-accent"
        aria-hidden="true"
      ></span>
      <.row_body
        row={@row}
        current_user={@current_user}
        cards={@cards}
        composing={@composing}
        socket={@socket}
      />
    </article>
    """
  end

  attr(:row, :map, required: true)
  attr(:current_user, :any, required: true)
  attr(:cards, :map, required: true)
  attr(:composing, :any, required: true)
  attr(:socket, :any, required: true)

  defp row_body(%{row: %{type: :words, item: item}} = assigns) do
    post = Map.get(assigns.cards.card_posts, card_post_id(item))
    note = Map.get(assigns.cards.notes, item[:note_id])
    subject = Map.get(assigns.cards.posts, subject_post_id(item))

    answer =
      case item[:answer] do
        %Post{} = answer -> answer
        _ -> nil
      end

    assigns =
      assign(assigns,
        item: item,
        post: post,
        note: note,
        subject: subject,
        answer: answer
      )

    ~H"""
    <p class="mb-1 flex min-w-0 items-center gap-1.5 text-xs text-slate-500 dark:text-slate-400">
      <span class="shrink-0" aria-hidden="true">↩︎</span>
      <span class="shrink-0">{context_label(@item)}</span>
      <.link
        :if={@subject}
        href={Posts.path(@subject)}
        class="min-w-0 truncate hover:text-brand-700 dark:hover:text-brand-300"
      >
        „{PostTeaser.plain_line(@subject, length: 120)}“
      </.link>
    </p>

    <.post_card
      :if={@post}
      post={@post}
      viewer={@current_user}
      conn_or_socket={@socket}
      engagement={@cards.engagement[@post.id]}
      mode={:preview}
      surface={:flat}
      show_reply_banner={false}
      quotable={false}
      entry_id={"notification-#{@row.id}"}
    />
    <.remote_reply_card :if={@note} note={@note} viewer={@current_user} marks={@cards.marks[@note.id]} live? />
    <p :if={!@post and !@note} class="mb-2 text-sm text-slate-700 dark:text-slate-300">
      <.actor_link actor={Timeline.actor(@item)} /> {notification_text(@item)}
    </p>

    <p :if={@answer} data-answer class="mb-2 truncate text-sm text-emerald-700 dark:text-emerald-300">
      ↩︎
      <.link href={Posts.path(@answer)} class="font-semibold hover:underline">
        {gettext("Your answer:")}
      </.link>
      {PostTeaser.plain_line(@answer, length: 160)}
    </p>

    <div :if={@composing == @row.id} class="mb-2 space-y-2">
      <.live_component
        module={VutuvWeb.PostLive.Composer}
        id={"answer-#{@row.id}"}
        host={:inline_reply}
        current_user={@current_user}
        post={nil}
        parent={@post}
        remote_note={@note}
        surface={:flat}
      />
      <button
        type="button"
        phx-click="cancel-compose"
        class="min-h-10 rounded-lg px-3 text-sm font-semibold text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"
      >
        {gettext("Cancel")}
      </button>
    </div>
    """
  end

  # Likes and re-shares of one post, drawn like the bottom line of a feed
  # card: the heart and the arrows with their counts, the faces beside them,
  # and every name behind a press on the faces.
  defp row_body(%{row: %{type: :reactions} = row} = assigns) do
    assigns =
      assign(assigns,
        post: Map.get(assigns.cards.posts, row.post_id),
        faces: Enum.take(row.actors, @stack_faces),
        more: length(row.actors) - @stack_faces
      )

    ~H"""
    <span class={[
      "mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full",
      if(@row.likes > 0,
        do: "bg-rose-50 text-accent dark:bg-rose-900/30",
        else: "bg-brand-50 text-brand-600 dark:bg-brand-800/60 dark:text-brand-300"
      )
    ]}>
      <.icon_heart :if={@row.likes > 0} filled? class="h-5 w-5" />
      <.icon_repost :if={@row.likes == 0} class="h-5 w-5" />
    </span>
    <div class="min-w-0 flex-1">
      <.link
        :if={@post}
        href={Posts.path(@post)}
        class="block truncate text-sm text-slate-700 hover:text-brand-700 dark:text-slate-300 dark:hover:text-brand-300"
      >
        „{PostTeaser.plain_line(@post, length: 200)}“
      </.link>
      <div class="mt-1 flex flex-wrap items-center gap-x-4 gap-y-1">
        <span
          :if={@row.likes > 0}
          data-reaction="likes"
          class="inline-flex items-center gap-1.5 text-sm font-semibold text-accent"
          title={likes_label(@row.likes)}
        >
          <.icon_heart filled? class="h-5 w-5" />{compact_count(@row.likes)}
        </span>
        <span
          :if={@row.shares > 0}
          data-reaction="shares"
          class="inline-flex items-center gap-1.5 text-sm font-semibold text-brand-600 dark:text-brand-300"
          title={shares_label(@row.shares)}
        >
          <.icon_repost class="h-5 w-5" />{compact_count(@row.shares)}
        </span>
        <details data-menu class="relative" id={"reactors-#{@row.id}"}>
          <summary
            aria-label={gettext("Who reacted")}
            class="flex min-h-9 cursor-pointer list-none items-center gap-1 rounded-full pr-1 hover:bg-slate-100 dark:hover:bg-slate-800 [&::-webkit-details-marker]:hidden"
          >
            <span class="flex items-center" aria-hidden="true">
              <span
                :for={{actor, index} <- Enum.with_index(@faces)}
                class={["rounded-full ring-2 ring-white dark:ring-slate-900", index > 0 && "-ml-1.5"]}
              >
                <.reactor_face actor={actor} />
              </span>
              <span
                :if={@more > 0}
                class="-ml-1.5 inline-flex h-5 items-center rounded-full bg-slate-100 px-1.5 text-[10px] font-bold text-slate-600 ring-2 ring-white dark:bg-slate-800 dark:text-slate-300 dark:ring-slate-900"
              >
                +{compact_count(@more)}
              </span>
            </span>
            <svg
              class="h-4 w-4 text-slate-400"
              fill="none"
              viewBox="0 0 24 24"
              stroke-width="2"
              stroke="currentColor"
              aria-hidden="true"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="m19.5 8.25-7.5 7.5-7.5-7.5" />
            </svg>
          </summary>
          <ul class="absolute left-0 z-30 mt-1 max-h-72 w-72 max-w-[80vw] space-y-0.5 overflow-y-auto rounded-xl bg-white p-2 shadow-lg ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-700">
            <li :for={actor <- @row.actors} data-reactor class="flex min-h-9 items-center gap-2 px-1">
              <.reactor_face actor={actor} />
              <span class="min-w-0 flex-1 truncate text-sm">
                <.actor_link actor={actor} /><span
                  :if={actor.handle && actor.handle != actor.name}
                  class="ml-1 text-xs text-slate-500 dark:text-slate-400"
                >{actor.handle}</span>
              </span>
              <.icon_heart :if={actor.liked?} filled? class="h-4 w-4 shrink-0 text-accent" />
              <.icon_repost
                :if={actor.shared?}
                class="h-4 w-4 shrink-0 text-brand-600 dark:text-brand-300"
              />
            </li>
          </ul>
        </details>
      </div>
    </div>
    <.row_time at={@row.at} />
    """
  end

  defp row_body(%{row: %{type: :people, persons: persons}} = assigns) do
    assigns = assign(assigns, :persons, persons)

    ~H"""
    <span class={[
      "mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-sm font-bold",
      kind_classes("follower")
    ]}>
      {kind_glyph("follower")}
    </span>
    <div class="min-w-0 flex-1 text-sm text-slate-800 dark:text-slate-100">
      <p class="mb-1 font-semibold">
        <%= if length(@persons) == 1 do %>
          <.actor_link actor={hd(@persons)} /> <span class="font-normal">{gettext("follows you")}</span>
        <% else %>
          {ngettext("%{formatted} new contact", "%{formatted} new contacts", length(@persons),
            formatted: compact_count(length(@persons))
          )}
        <% end %>
      </p>
      <ul class="flex flex-wrap gap-x-4 gap-y-1.5">
        <li :for={person <- @persons} class="flex items-center gap-2">
          <.actor_link :if={length(@persons) > 1} actor={person} />
          <span
            :if={person.connected?}
            class="rounded-full bg-emerald-50 px-2 text-xs font-semibold text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-300"
          >
            {pgettext("contact", "connected")}
          </span>
          <button
            :if={!person.connected? and person.kind != "organization" and person.id}
            type="button"
            phx-click="follow"
            phx-value-followee={person.id}
            class="min-h-8 rounded-full px-3 text-xs font-semibold text-brand-700 ring-1 ring-brand-600 hover:bg-brand-50 dark:text-brand-300 dark:ring-brand-400 dark:hover:bg-brand-800/30"
          >
            {gettext("Follow back")}
          </button>
        </li>
      </ul>
    </div>
    <.row_time at={@row.at} />
    """
  end

  defp row_body(%{row: %{type: :other, item: item}} = assigns) do
    assigns =
      assign(assigns,
        n: item,
        actor: item[:actor_name] && Timeline.actor(item),
        target: notification_target(item, assigns.current_user)
      )

    ~H"""
    <.row_visual kind={@n.kind} actor={@actor} />
    <div class="min-w-0 flex-1">
      <p class="mb-0 text-sm leading-relaxed text-slate-800 dark:text-slate-100">
        <.actor_link :if={@actor} actor={@actor} />
        <%= cond do %>
          <% @n.kind == "username" -> %>
            <.username_line handle={@n.username} />
          <% @target -> %>
            <.link href={@target} class="hover:text-brand-700 hover:underline dark:hover:text-brand-300">
              {notification_text(@n)}
            </.link>
          <% true -> %>
            {notification_text(@n)}
        <% end %>
      </p>

      <ul :if={@n.kind == "cv_update" and (@n[:entry_count] || 0) > 1} class="mt-1.5 space-y-0.5" data-cv-entries="true">
        <li :for={entry <- @n[:entries] || []} class="text-sm">
          <.link
            href={cv_entry_path(@n, entry)}
            class="text-slate-600 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
          >
            {cv_entry_label(entry)}
          </.link>
        </li>
        <li :if={cv_entries_more(@n) > 0} class="text-xs text-slate-600 dark:text-slate-400">
          {gettext("and %{count} more", count: compact_count(cv_entries_more(@n)))}
        </li>
      </ul>

      <div :if={@n.kind == "handle_change"} class="mt-1.5 space-y-1" data-change-posts="true">
        <.link
          :for={post <- change_posts(@n, @cards.posts)}
          href={Posts.path(post)}
          class="block text-sm text-slate-600 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
        >
          <span class="line-clamp-1">{PostTeaser.plain_line(post, length: 120)}</span>
        </.link>
        <p :if={change_posts_more(@n) > 0} class="mb-0 text-xs text-slate-600 dark:text-slate-400">
          {gettext("and %{count} more", count: compact_count(change_posts_more(@n)))}
        </p>
      </div>
    </div>
    <.row_time at={@row.at} />
    """
  end

  # ── Pieces ──

  # One small face: the member's picture, or their initials for a picture-less
  # member and for somebody on another network.
  attr(:actor, :map, required: true)

  defp reactor_face(assigns) do
    ~H"""
    <.avatar :if={@actor.avatar} src={@actor.avatar} size="2xs" alt="" />
    <span
      :if={!@actor.avatar}
      class="flex h-5 w-5 items-center justify-center rounded-full bg-slate-200 text-[9px] font-bold text-slate-600 dark:bg-slate-700 dark:text-slate-200"
      aria-hidden="true"
    >
      {name_initials(String.trim_leading(@actor.name || "?", "@"))}
    </span>
    """
  end

  attr(:kind, :string, required: true)
  attr(:actor, :any, required: true)

  defp row_visual(assigns) do
    ~H"""
    <%= if @actor && @actor.avatar do %>
      <.link href={@actor.param && actor_target(%{actor_kind: @actor.kind, actor_param: @actor.param})} class="relative mt-0.5 shrink-0 self-start">
        <.presence_wrap id={@actor.id} size="sm">
          <.avatar src={@actor.avatar} size="sm" alt={gettext("Avatar of %{name}", name: @actor.name)} />
        </.presence_wrap>
        <span
          class={[
            "absolute -bottom-1 -left-1 z-20 flex h-5 w-5 items-center justify-center rounded-full text-[10px] font-bold ring-2 ring-white dark:ring-slate-900",
            kind_classes(@kind)
          ]}
          title={kind_label(@kind)}
        >
          {kind_glyph(@kind)}
        </span>
      </.link>
    <% else %>
      <span class={[
        "mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-sm font-bold",
        kind_classes(@kind)
      ]}>
        {kind_glyph(@kind)}
        <span class="sr-only">{kind_label(@kind)}</span>
      </span>
    <% end %>
    """
  end

  # One actor's name, linked: a member or a page to their page here, somebody
  # on another network to their account card, anybody else as a bare name.
  # One line of markup on purpose: it sits inside a sentence.
  attr(:actor, :map, required: true)

  defp actor_link(assigns) do
    assigns =
      assigns
      |> assign(:remote?, is_nil(assigns.actor.param) and is_binary(assigns.actor[:url]))
      |> assign(:bare?, is_nil(assigns.actor.param) and not is_binary(assigns.actor[:url]))

    ~H"""
    <.link :if={@actor.param} href={actor_target(%{actor_kind: @actor.kind, actor_param: @actor.param})} class={actor_name_class()}>{@actor.name}</.link><.link :if={@remote?} {remote_actor_link(nil, @actor.url, @actor[:handle])} class={actor_name_class()}>{@actor.name}</.link><span :if={@bare?} class="font-semibold">{@actor.name}</span>
    """
  end

  defp actor_name_class,
    do:
      "font-semibold text-slate-900 hover:text-brand-700 dark:text-white dark:hover:text-brand-300"

  # The welcome note: the handle, the settings page and the import page are
  # each a link of their own, split out of one translation (split_marker/2,
  # which cannot raise on a botched .po). Neither language may end a sentence
  # on a URL.
  attr(:handle, :string, required: true)

  defp username_line(assigns) do
    {greeting, rest} =
      split_marker(
        gettext(
          "Welcome to vutuv! You can change your automatically assigned username {handle} on the {url} page. At {import_url} you can import your existing LinkedIn profile."
        ),
        "{handle}"
      )

    {between, rest} = split_marker(rest, "{url}")
    {before_import, tail} = split_marker(rest, "{import_url}")

    assigns =
      assign(assigns,
        greeting: greeting,
        between: between,
        before_import: before_import,
        tail: tail,
        settings_url: url(~p"/settings/username"),
        import_url: url(~p"/settings/import/linkedin")
      )

    ~H"""
    {@greeting}<.link href={~p"/#{@handle}"} class={inline_link_class()}>@{@handle}</.link>{@between}<.link href={@settings_url} class={inline_link_class()}>{@settings_url}</.link>{@before_import}<.link href={@import_url} class={inline_link_class()}>{@import_url}</.link>{@tail}
    """
  end

  defp inline_link_class,
    do:
      "font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"

  # The row's clock time in the reader's zone; the <time> keeps the UTC instant
  # for machines.
  attr(:at, :any, required: true)

  defp row_time(assigns) do
    utc = DateTime.from_naive!(assigns.at, "Etc/UTC")

    assigns =
      assigns
      |> assign(:datetime, DateTime.to_iso8601(utc))
      |> assign(:title, ViewerClock.format(utc, :datetime))
      |> assign(:clock, ViewerClock.format(utc, :time))

    ~H"""
    <time
      datetime={@datetime}
      title={@title}
      class="shrink-0 pt-0.5 text-xs tabular-nums text-slate-500 dark:text-slate-400"
    >
      {@clock}
    </time>
    """
  end

  # ── Words ──

  defp day_label(day) do
    today = ViewerClock.today()

    cond do
      day == today -> gettext("Today")
      day == Date.add(today, -1) -> gettext("Yesterday")
      true -> long_date(day)
    end
  end

  defp fresh_label(count, since) do
    ngettext(
      "%{formatted} new since your visit at %{time}",
      "%{formatted} new since your visit at %{time}",
      count,
      formatted: compact_count(count),
      time: ViewerClock.format(since, :time)
    )
  end

  defp context_label(%{kind: "thread"}), do: gettext("Reply in the thread on")
  defp context_label(%{kind: "mention"}), do: gettext("Mentions you")
  defp context_label(_item), do: gettext("Reply to your post")

  defp likes_label(count),
    do:
      ngettext("%{formatted} like", "%{formatted} likes", count, formatted: compact_count(count))

  defp shares_label(count),
    do:
      ngettext("%{formatted} repost", "%{formatted} reposts", count,
        formatted: compact_count(count)
      )

  # A handle change names the newest of the member's own posts it rewrote.
  defp change_posts(%{post_ids: ids}, posts) when is_list(ids) do
    ids
    |> Enum.sort(:desc)
    |> Enum.take(@change_preview_limit)
    |> Enum.map(&Map.get(posts, &1))
    |> Enum.filter(&match?(%Post{}, &1))
  end

  defp change_posts(_item, _posts), do: []

  # How many rewritten posts are beyond the ones named; a post the member can
  # no longer see still counts, it was rewritten all the same.
  defp change_posts_more(%{post_ids: ids}) when is_list(ids),
    do: max(length(ids) - @change_preview_limit, 0)

  defp change_posts_more(_item), do: 0

  # How many of a CV update's entries are not in the list it carries.
  defp cv_entries_more(n), do: (n[:entry_count] || 0) - length(n[:entries] || [])
end
