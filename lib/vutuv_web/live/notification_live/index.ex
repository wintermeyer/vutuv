defmodule VutuvWeb.NotificationLive.Index do
  @moduledoc """
  Notifications page. The feed is real data derived at read time by
  `Vutuv.Activity.notifications_page/2` from the event tables that already
  exist, so it reaches back to events from before this page existed.

  Presentation (the 2026-07 redesign):

    * Raw events are **merged into grouped rows** under **Berlin-day sections**
      by `VutuvWeb.NotificationLive.Groups` - same-day likes of one post, the
      day's followers, one endorser's endorsements each read as a single row
      instead of a card per event.
    * Events newer than the previous visit's read marker are highlighted as
      unread (tint + coral dot); the visit itself still advances the marker
      and clears the shell's bell badge, exactly as before.
    * **Filter tabs** (all / posts / people / more) restrict the feed
      server-side via `notifications_page`'s `kinds:` option and live in the
      URL (`?filter=`), patched without a reload.
    * A rail (right column on md+, below the list on phones) offers **Follow
      back** suggestions (recent followers, reload-free follow via
      `Vutuv.Social`) and a **Last 30 days** summary
      (`Vutuv.Activity.activity_summary/2`).

  The first page renders on the **static** mount too (issue #919), so the
  list is in the first HTTP paint. Older pages load via "Load more" (cursor
  pagination); live events arrive over `Vutuv.Activity` (PubSub `"user:<id>"`)
  and merge into their group. Because grouping is a pure function over the
  retained item list, every change (load more, live push, the DayClock's
  midnight rollover) simply recomputes the sections - there is no stream to
  patch in place.
  """
  use VutuvWeb, :live_view

  import VutuvWeb.UserHTML, only: [user_row: 1]

  # Like the feed and messages: not a page for anonymous visitors —
  # redirect to /login instead of rendering an empty 200.
  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Activity
  alias Vutuv.BerlinTime
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Social
  alias VutuvWeb.NotificationLive.Groups
  alias VutuvWeb.UserHelpers

  @page_size 50
  @summary_days 30
  @follow_back_limit 5

  # The filter tabs: each maps to the event kinds `notifications_page`'s
  # `kinds:` option keeps. "all" passes nil (every source).
  @filters %{
    "all" => nil,
    "posts" => ~w(reply like),
    "people" => ~w(follower connection endorsement),
    "other" =>
      ~w(organization_role moderation image_rejected report_protection handle_change cv_update)
  }

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # The previous visit's read marker - what "new since your last visit"
    # highlights - and its badge count, both captured *before* this visit
    # advances the marker below.
    read_marker = user.notifications_read_at
    new_count = if connected?(socket), do: Activity.unread_notification_count(user.id), else: 0

    if connected?(socket) do
      Activity.subscribe(user.id)
      Activity.mark_notifications_read(user.id)
      # Roll the day sections over at Berlin midnight without a reload.
      Vutuv.DayClock.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Notifications"))
     |> assign(:read_marker, read_marker)
     |> assign(:new_count, new_count)
     |> assign(:today, BerlinTime.today())
     |> assign_rail(connected?(socket))}
  end

  # The filter lives in the URL (?filter=posts), so tabs are patch links and
  # the back button works; an unknown value falls back to "all". Runs on both
  # the static and the connected mount, so the first page is in the first
  # HTTP paint (issue #919).
  @impl true
  def handle_params(params, _uri, socket) do
    filter = if Map.has_key?(@filters, params["filter"]), do: params["filter"], else: "all"

    {:noreply, socket |> assign(:filter, filter) |> load_first_page()}
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    page =
      Activity.notifications_page(socket.assigns.current_user.id,
        limit: @page_size,
        kinds: @filters[socket.assigns.filter],
        cursor: socket.assigns.cursor
      )

    items = with_post_previews(page.entries, socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> assign(:remaining, max(socket.assigns.remaining - length(page.entries), 0))
     |> update(:items, &(&1 ++ items))
     |> assign_sections()}
  end

  # The rail's "Follow back" pill (user_row live?): follow with no reload,
  # then recompute the rail so the new followee drops out.
  def handle_event("follow", %{"followee" => followee_id}, socket) do
    case Social.follow(socket.assigns.current_user, followee_id) do
      {:ok, _} -> {:noreply, assign_rail(socket, true)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("unfollow", %{"id" => follow_id}, socket) do
    # Scoped to the viewer, so a request can only drop the viewer's own edge.
    Social.unfollow!(socket.assigns.current_user.id, follow_id)
    {:noreply, assign_rail(socket, true)}
  end

  @impl true
  def handle_info({:new_notification, notification}, socket) do
    # The user is watching the event arrive, so it is already read: advance
    # the read marker, which broadcasts :notifications_read and keeps the
    # shell's bell badge at zero instead of bumping it for an event shown
    # live here.
    Activity.mark_notifications_read(socket.assigns.current_user.id)

    item =
      notification
      |> Map.put_new(:kind, "activity")
      |> Map.put_new(:at, DateTime.utc_now())
      # Pushed events carry no row id, so mint one outside the derived
      # "<kind>-<row id>" namespace. A CV update brings its own derived group
      # id, so a second entry within the grouping window replaces the row an
      # open page already shows instead of stacking another.
      |> Map.put_new(:id, "live-#{System.unique_integer([:positive, :monotonic])}")

    if filtered_out?(item, socket.assigns.filter) do
      {:noreply, socket}
    else
      [item] = with_post_previews([item], socket.assigns.current_user)

      {:noreply,
       socket
       |> update(:items, fn items -> [item | Enum.reject(items, &(&1.id == item.id))] end)
       |> assign_sections()}
    end
  end

  # The Berlin day rolled over at midnight (Vutuv.DayClock): recompute the
  # sections so "Today" becomes "Yesterday" without a reload.
  def handle_info(:day_changed, socket) do
    {:noreply, socket |> assign(:today, BerlinTime.today()) |> assign_sections()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load_first_page(socket) do
    user = socket.assigns.current_user
    kinds = @filters[socket.assigns.filter]

    page = Activity.notifications_page(user.id, limit: @page_size, kinds: kinds)

    # The exact feed size backs the "Load N of M more" countdown, but a full
    # count across every source is the heaviest query on this page: compute it
    # only on the connected, unfiltered mount (the static first paint and the
    # filter tabs fall back to a plain "Load more" label).
    remaining =
      if connected?(socket) and kinds == nil,
        do: max(Activity.notifications_count(user.id) - length(page.entries), 0),
        else: 0

    socket
    |> assign(:items, with_post_previews(page.entries, user))
    |> assign(:more?, page.more?)
    |> assign(:cursor, page.next_cursor)
    |> assign(:remaining, remaining)
    |> assign_sections()
  end

  defp assign_sections(socket) do
    sections = Groups.sections(socket.assigns.items, socket.assigns.read_marker)

    socket
    |> assign(:sections, sections)
    |> assign(:empty?, sections == [])
  end

  defp filtered_out?(item, filter) do
    case @filters[filter] do
      nil -> false
      kinds -> item.kind not in kinds
    end
  end

  # The rail data (follow-back suggestions + 30-day summary) is skipped on
  # the static mount, like the remaining count, to keep the first paint lean.
  defp assign_rail(socket, false) do
    socket
    |> assign(:follow_back, [])
    |> assign(:work_info_by_id, %{})
    |> assign(:summary, nil)
  end

  defp assign_rail(socket, true) do
    user = socket.assigns.current_user
    follow_back = Social.followers_to_follow_back(user.id, @follow_back_limit)

    since = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -@summary_days, :day)
    summary = Activity.activity_summary(user.id, since)

    socket
    |> assign(:follow_back, follow_back)
    |> assign(:work_info_by_id, UserHelpers.work_information_map(follow_back, 45))
    |> assign(:summary, if(summary_total(summary) > 0, do: summary))
  end

  defp summary_total(summary) do
    summary.followers + summary.connections + summary.likes + summary.replies +
      summary.endorsements
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="notifications" class="py-6 md:py-8">
      <div class="grid gap-6 md:grid-cols-3">
        <div class="min-w-0 md:col-span-2">
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">
              {gettext("Notifications")}
            </h1>
            <p :if={@new_count > 0} id="new-count" class="mb-0 text-sm font-semibold text-accent">
              {new_count_label(@new_count)}
            </p>
          </div>

          <div class="mt-4 flex gap-1 overflow-x-auto rounded-lg bg-slate-100 p-1 text-sm dark:bg-slate-800">
            <.link
              :for={{value, label} <- filter_options()}
              patch={filter_path(value)}
              data-notif-filter-tab={value}
              aria-current={@filter == value && "page"}
              class={filter_tab_class(@filter == value)}
            >
              {label}
            </.link>
          </div>

          <section :for={section <- @sections} data-day-section>
            <h2
              class="mb-0 mt-6 text-sm font-semibold uppercase tracking-wide text-slate-500"
              data-day-heading
            >
              {day_label(section.day, @today)}
            </h2>
            <div class="mt-2 divide-y divide-slate-100 overflow-hidden rounded-2xl bg-white shadow-sm ring-1 ring-slate-200 dark:divide-slate-800 dark:bg-slate-900 dark:ring-slate-800">
              <.notification_row :for={group <- section.groups} group={group} current_user={@current_user} />
            </div>
          </section>

          <p :if={@empty?} class="mt-6 text-slate-600 dark:text-slate-400">
            {gettext("Nothing new yet.")}
          </p>

          <.load_more :if={@more?} class="mt-6">{load_more_label(@remaining)}</.load_more>
        </div>

        <aside class="min-w-0 space-y-6">
          <.card :if={@follow_back != []} id="follow-back" class="p-5">
            <.section_title>{gettext("Follow back")}</.section_title>
            <ul class="mt-4 space-y-4">
              <.user_row
                :for={member <- @follow_back}
                user={member}
                current_user={@current_user}
                current_user_id={@current_user.id}
                work_info_by_id={@work_info_by_id}
                following_by_id={%{}}
                live?
              />
            </ul>
          </.card>

          <.card :if={@summary} id="activity-summary" class="p-5">
            <.section_title>{gettext("Last 30 days")}</.section_title>
            <ul class="mt-4 space-y-2.5">
              <li
                :for={{kind, count} <- summary_rows(@summary)}
                class="flex items-center gap-3 text-sm"
              >
                <span class={[
                  "flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xs font-bold",
                  kind_classes(kind)
                ]}>
                  {kind_glyph(kind)}
                </span>
                <span class="min-w-0 flex-1 truncate text-slate-700 dark:text-slate-300">
                  {summary_label(kind)}
                </span>
                <span class="font-semibold text-slate-900 dark:text-white">
                  {compact_count(count)}
                </span>
              </li>
            </ul>
          </.card>
        </aside>
      </div>
    </div>
    """
  end

  # ── One grouped row ──

  attr(:group, :map, required: true)
  attr(:current_user, :any, required: true)

  defp notification_row(assigns) do
    assigns = assign(assigns, :n, assigns.group.item)

    ~H"""
    <article
      id={"notification-#{@group.id}"}
      data-notification-row
      data-kind={@group.kind}
      data-unread={@group.unread? && "true"}
      class={[
        "flex gap-3 px-4 py-3 sm:px-5",
        @group.unread? && "bg-brand-50/60 dark:bg-brand-900/15"
      ]}
    >
      <.row_visual group={@group} />
      <div class="min-w-0 flex-1">
        <p class="mb-0 text-sm leading-relaxed text-slate-800 dark:text-slate-100">
          <.actor_links group={@group} current_user={@current_user} />
          <% target = notification_target(@n, @current_user) %>
          <%= if target do %>
            <.link href={target} class="hover:text-brand-700 hover:underline dark:hover:text-brand-300">
              {group_text(@group)}
            </.link>
          <% else %>
            {group_text(@group)}
          <% end %>
        </p>

        <%!-- A like quotes the liked post once, one small excerpt linking to it. --%>
        <.link
          :if={@group.kind == "like" and @n[:post_preview]}
          data-post-preview="true"
          href={~p"/#{@current_user}/posts/#{@n.post_id}"}
          class="mt-1.5 block border-l-2 border-slate-200 pl-2.5 text-sm text-slate-600 hover:text-brand-700 dark:border-slate-700 dark:text-slate-400 dark:hover:text-brand-300"
        >
          <span class="line-clamp-2 whitespace-pre-line">{@n.post_preview.text}</span>
        </.link>

        <%!-- A reply quotes the recipient's own post (context) and the reply
        itself, each one compact excerpt linking to its permalink. --%>
        <div
          :if={@group.kind == "reply" and (@n[:post_preview] || @n[:reply_preview])}
          class="mt-1.5 space-y-1"
        >
          <.link
            :if={@n[:post_preview]}
            data-post-preview="true"
            href={~p"/#{@current_user}/posts/#{@n.post_id}"}
            class="block text-xs text-slate-500 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
          >
            <span class="font-medium">{gettext("Your post")}:</span>
            <span class="line-clamp-1 whitespace-pre-line align-bottom">{@n.post_preview.text}</span>
          </.link>
          <.link
            :if={@n[:reply_preview]}
            data-reply-preview="true"
            href={~p"/#{@n.reply_preview.post.user}/posts/#{@n.reply_preview.post.id}"}
            class="block border-l-2 border-slate-200 pl-2.5 text-sm text-slate-600 hover:text-brand-700 dark:border-slate-700 dark:text-slate-400 dark:hover:text-brand-300"
          >
            <span class="line-clamp-2 whitespace-pre-line">{@n.reply_preview.text}</span>
          </.link>
        </div>

        <%!-- A CV update covering several entries names them, each linking to
        its own page (issue #980). A single entry is named in the line itself. --%>
        <div
          :if={@group.kind == "cv_update" and (@n[:entry_count] || 0) > 1}
          class="mt-1.5"
          data-cv-entries="true"
        >
          <ul class="space-y-0.5">
            <li :for={entry <- @n[:entries] || []} class="text-sm">
              <.link
                href={cv_entry_path(@n, entry)}
                class="text-slate-600 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
              >
                {cv_entry_label(entry)}
              </.link>
            </li>
          </ul>
          <p :if={cv_entries_more(@n) > 0} class="mb-0 mt-1 text-xs text-slate-600 dark:text-slate-400">
            {gettext("and %{count} more", count: compact_count(cv_entries_more(@n)))}
          </p>
        </div>

        <%!-- A handle change lists the recipient's own rewritten posts as
        compact excerpt links, plus a count of any remaining ones. --%>
        <div :if={@group.kind == "handle_change"} class="mt-1.5 space-y-1" data-change-posts="true">
          <.link
            :for={cp <- @n[:change_posts] || []}
            href={~p"/#{@current_user}/posts/#{cp.post.id}"}
            class="block text-sm text-slate-600 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
          >
            <span class="line-clamp-1 whitespace-pre-line">{cp.text}</span>
          </.link>
          <p :if={handle_change_more(@n) > 0} class="mb-0 text-xs text-slate-600 dark:text-slate-400">
            {gettext("and %{count} more", count: compact_count(handle_change_more(@n)))}
          </p>
        </div>
      </div>
      <div class="flex shrink-0 flex-col items-end gap-1.5 pt-0.5">
        <.row_time at={@group.at} />
        <span :if={@group.unread?} class="h-2 w-2 rounded-full bg-accent">
          <span class="sr-only">{gettext("New")}</span>
        </span>
      </div>
    </article>
    """
  end

  # The row's left visual: the lead (newest) actor's avatar with a small
  # kind badge riding its corner - or, for a picture-less lead actor and the
  # actor-less kinds (moderation, image review), the colored kind glyph
  # circle. Either way a present actor gets the online-presence dot via
  # <.presence_wrap> (the dot sits bottom-right, the kind badge bottom-left).
  attr(:group, :map, required: true)

  defp row_visual(assigns) do
    assigns = assign(assigns, :lead, List.first(assigns.group.actors))

    ~H"""
    <%= if @lead && @lead.avatar do %>
      <.link href={@lead.param && ~p"/#{@lead.param}"} class="relative mt-0.5 shrink-0 self-start">
        <.presence_wrap id={@lead.id} size="sm">
          <.avatar src={@lead.avatar} size="sm" alt={"Avatar of #{@lead.name}"} />
        </.presence_wrap>
        <.kind_badge kind={@group.kind} />
      </.link>
    <% else %>
      <.presence_wrap id={@lead && @lead.id} size="sm">
        <span class={[
          "mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-sm font-bold",
          kind_classes(@group.kind)
        ]}>
          {kind_glyph(@group.kind)}
          <span class="sr-only">{kind_label(@group.kind)}</span>
        </span>
      </.presence_wrap>
    <% end %>
    """
  end

  attr(:kind, :string, required: true)

  defp kind_badge(assigns) do
    ~H"""
    <span
      class={[
        "absolute -bottom-1 -left-1 z-20 flex h-5 w-5 items-center justify-center rounded-full text-[10px] font-bold ring-2 ring-white dark:ring-slate-900",
        kind_classes(@kind)
      ]}
      title={kind_label(@kind)}
    >
      {kind_glyph(@kind)}
      <span class="sr-only">{kind_label(@kind)}</span>
    </span>
    """
  end

  # The sentence's subject: up to two linked actor names, the rest folded
  # into "and N more" - which links to the recipient's own followers /
  # connections list where that is the natural place to see everyone.
  attr(:group, :map, required: true)
  attr(:current_user, :any, required: true)

  defp actor_links(assigns) do
    named = Enum.take(assigns.group.actors, Groups.named_actors())
    overflow = assigns.group.actor_count - length(named)

    assigns =
      assigns
      |> assign(:named, named)
      |> assign(:overflow, overflow)
      |> assign(:overflow_href, overflow_href(assigns.group.kind, assigns.current_user))

    ~H"""
    <span :for={{actor, index} <- Enum.with_index(@named)}>{separator(index, length(@named), @overflow)}<.actor_link actor={actor} /></span>
    <span :if={@overflow > 0}>
      <%= if @overflow_href do %>
        <.link
          href={@overflow_href}
          class="font-semibold text-slate-900 hover:text-brand-700 dark:text-white dark:hover:text-brand-300"
        >{gettext("and %{count} more", count: compact_count(@overflow))}</.link>
      <% else %>
        <span class="font-semibold">{gettext("and %{count} more", count: compact_count(@overflow))}</span>
      <% end %>
    </span>
    """
  end

  attr(:actor, :map, required: true)

  defp actor_link(assigns) do
    ~H"""
    <%= if @actor.param do %>
      <.link
        href={~p"/#{@actor.param}"}
        class="font-semibold text-slate-900 hover:text-brand-700 dark:text-white dark:hover:text-brand-300"
      >{@actor.name}</.link>
    <% else %>
      <span class="font-semibold">{@actor.name}</span>
    <% end %>
    """
  end

  # "A and B liked" / "A, B and 3 more liked": the separator *before* the
  # name at `index`. The joining word only appears when B is the last named
  # actor and nothing overflows (the overflow chunk brings its own "and").
  defp separator(0, _named, _overflow), do: ""
  defp separator(_index, _named, overflow) when overflow > 0, do: ", "
  defp separator(index, named, _overflow) when index == named - 1, do: " #{gettext("and")} "
  defp separator(_index, _named, _overflow), do: ", "

  # Where "and N more" leads: the recipient's own people lists for the
  # people kinds; nowhere for a like group (there is no public likers list).
  defp overflow_href("follower", viewer), do: ~p"/#{viewer}/followers"
  defp overflow_href("connection", viewer), do: ~p"/#{viewer}/connections"
  defp overflow_href(_kind, _viewer), do: nil

  # ── Header bits ──

  defp filter_options do
    [
      {"all", gettext("All")},
      {"posts", gettext("Posts")},
      {"people", gettext("People")},
      {"other", gettext("More")}
    ]
  end

  defp filter_path("all"), do: ~p"/notifications"
  defp filter_path(value), do: ~p"/notifications?filter=#{value}"

  # The active tab reads as a raised white pill, the rest as quiet muted text
  # - the segmented-control treatment of the post-type filter tabs.
  defp filter_tab_class(true),
    do:
      "whitespace-nowrap rounded-md bg-white px-3 py-1 font-semibold text-brand-700 shadow-sm dark:bg-slate-900 dark:text-brand-100"

  defp filter_tab_class(false),
    do:
      "whitespace-nowrap rounded-md px-3 py-1 font-medium text-slate-600 hover:text-slate-900 dark:text-slate-400 dark:hover:text-slate-100"

  defp new_count_label(count) do
    ngettext("%{formatted} new notification", "%{formatted} new notifications", count,
      formatted: compact_count(count)
    )
  end

  defp day_label(day, today) do
    cond do
      day == today ->
        gettext("Today")

      day == Date.add(today, -1) ->
        gettext("Yesterday")

      true ->
        gettext("%{month} %{day}, %{year}",
          month: month_name(day.month),
          day: day.day,
          year: day.year
        )
    end
  end

  # The row's clock time: sections are Berlin calendar days, so the visible
  # time is the Berlin wall clock (the site's canonical clock, like post
  # stamps); the <time> keeps an unambiguous ISO-8601 UTC datetime for
  # machines. Server-rendered final - deliberately no data-localtime rewrite.
  attr(:at, :any, required: true)

  defp row_time(assigns) do
    utc = DateTime.from_naive!(assigns.at, "Etc/UTC")
    berlin = BerlinTime.naive(utc)

    assigns =
      assigns
      |> assign(:datetime, DateTime.to_iso8601(utc))
      |> assign(:title, Calendar.strftime(berlin, "%Y-%m-%d %H:%M"))
      |> assign(:clock, Calendar.strftime(berlin, "%H:%M"))

    ~H"""
    <time datetime={@datetime} title={@title} class="text-xs tabular-nums text-slate-500">
      {@clock}
    </time>
    """
  end

  # "Load 50 of 80 more": the next batch size, then everything still unloaded.
  # `remaining` is a mount-time snapshot of the (unfiltered) feed size, so a
  # filtered tab and a run-dry snapshot both fall back to the plain label.
  defp load_more_label(remaining) when remaining <= 0, do: gettext("Load more")

  defp load_more_label(remaining) do
    gettext("Load %{count} of %{remaining} more",
      count: compact_count(min(@page_size, remaining)),
      remaining: compact_count(remaining)
    )
  end

  # ── The 30-day summary card ──

  defp summary_rows(summary) do
    [
      {"follower", summary.followers},
      {"connection", summary.connections},
      {"like", summary.likes},
      {"reply", summary.replies},
      {"endorsement", summary.endorsements}
    ]
    |> Enum.filter(fn {_kind, count} -> count > 0 end)
  end

  defp summary_label("follower"), do: gettext("Followers")
  defp summary_label("connection"), do: gettext("Connections")
  defp summary_label("like"), do: gettext("Likes")
  defp summary_label("reply"), do: gettext("Replies")
  defp summary_label("endorsement"), do: gettext("Endorsements")

  # ── Kind styling (badge colour + glyph + accessible label) ──

  # Event kinds that share the brand badge colour, so the class string lives
  # in one place.
  @brand_kind_classes "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"
  @brand_kinds ~w(follower reply connection report_protection organization_role handle_change cv_update)

  defp kind_classes("endorsement"),
    do: "bg-emerald-50 text-emerald-600 dark:bg-emerald-900/30 dark:text-emerald-300"

  defp kind_classes("like"), do: "bg-accent/10 text-accent dark:bg-accent/20"

  defp kind_classes("moderation"),
    do: "bg-amber-50 text-amber-600 dark:bg-amber-900/30 dark:text-amber-200"

  # The AI image scan removed an image — amber, like every moderation notice.
  defp kind_classes("image_rejected"),
    do: "bg-amber-50 text-amber-600 dark:bg-amber-900/30 dark:text-amber-200"

  defp kind_classes(kind) when kind in @brand_kinds, do: @brand_kind_classes

  defp kind_classes(_), do: "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-300"

  defp kind_glyph("follower"), do: "+"
  defp kind_glyph("endorsement"), do: "★"
  defp kind_glyph("reply"), do: "↩"
  defp kind_glyph("like"), do: "♥"
  # "connection" is the vernetzt (mutual-follow) event; the handshake glyph.
  defp kind_glyph("connection"), do: "🤝"
  defp kind_glyph("moderation"), do: "⚑"
  defp kind_glyph("image_rejected"), do: "🖼"
  defp kind_glyph("report_protection"), do: "🛡"
  defp kind_glyph("organization_role"), do: "🏢"
  defp kind_glyph("handle_change"), do: "@"
  defp kind_glyph("cv_update"), do: "📄"
  defp kind_glyph(_), do: "•"

  # The accessible kind name (the badge's title + sr-only text). Translated
  # like the row text; raw kind strings ("cv_update") must not leak to users.
  defp kind_label("follower"), do: gettext("Follower")
  defp kind_label("endorsement"), do: gettext("Endorsement")
  defp kind_label("reply"), do: gettext("Reply")
  defp kind_label("like"), do: gettext("Like")
  defp kind_label("connection"), do: gettext("Connection")
  defp kind_label("moderation"), do: gettext("Moderation")
  defp kind_label("image_rejected"), do: gettext("Image review")
  defp kind_label("report_protection"), do: gettext("Report protection")
  defp kind_label("organization_role"), do: gettext("Organization role")
  defp kind_label("handle_change"), do: gettext("Handle change")
  defp kind_label("cv_update"), do: gettext("CV update")
  defp kind_label(_), do: gettext("Activity")

  # ── The sentence ──

  # The grouped sentence tail after the actor names. English needs no
  # singular/plural split for "liked your post."; German does for the
  # follower/connection verbs, hence the count-branched msgids.
  defp group_text(%{kind: "follower", actor_count: count}) when count > 1,
    do: gettext("are now following you.")

  defp group_text(%{kind: "follower"}), do: gettext("started following you.")

  defp group_text(%{kind: "connection", actor_count: count}) when count > 1,
    do: gettext("are now connected with you.")

  defp group_text(%{kind: "connection"}), do: gettext("is now connected with you.")

  defp group_text(%{kind: "like"}), do: gettext("liked your post.")

  defp group_text(%{kind: "endorsement", tags: [tag]}),
    do: gettext("endorsed you for %{tag}.", tag: tag)

  defp group_text(%{kind: "endorsement", tags: [_ | _] = tags}),
    do: gettext("endorsed you for %{tags}.", tags: join_names(tags))

  defp group_text(%{item: item}), do: notification_text(item)

  # "Elixir, Phoenix and Rails" - all but the last joined by commas, the last
  # by the localized joining word.
  defp join_names([single]), do: single

  defp join_names(names) do
    {front, [last]} = Enum.split(names, -1)
    Enum.join(front, ", ") <> " " <> gettext("and") <> " " <> last
  end

  # Where clicking the event text leads. Events about one of the viewer's
  # posts open that post's thread; an endorsement the viewer's tags;
  # everything else the actor's profile. Moderation events lead to the
  # owner's case page (and carry no actor).
  defp notification_target(%{kind: "moderation"} = n, viewer) do
    if is_binary(n[:case_id]) and viewer != nil, do: ~p"/moderation/cases/#{n.case_id}"
  end

  # An organization-role grant opens the organization page it was granted on.
  defp notification_target(%{kind: "organization_role"} = n, _viewer) do
    if is_binary(n[:organization_slug]), do: ~p"/organizations/#{n.organization_slug}"
  end

  # A removed avatar/cover leads to the photos form (upload a new one), a
  # removed qualification proof to the credentials editor; other rejected
  # images have no page left to open.
  defp notification_target(%{kind: "image_rejected"} = n, viewer) do
    cond do
      viewer == nil -> nil
      n[:image_kind] in ["avatar", "cover"] -> ~p"/settings/profile"
      n[:image_kind] == "qualification_document" -> ~p"/settings/qualifications"
      true -> nil
    end
  end

  # A CV update (issue #980) opens the entry itself when the group holds
  # exactly one; a bigger group leads to the author's profile, where all of
  # them sit (the entries are listed and individually linked under the line).
  defp notification_target(%{kind: "cv_update"} = n, _viewer) do
    case n[:entries] do
      [entry] -> cv_entry_path(n, entry)
      _ -> actor_target(n)
    end
  end

  defp notification_target(n, viewer) do
    primary_target(n, viewer) || actor_target(n)
  end

  defp primary_target(%{kind: kind} = n, viewer) when kind in ["reply", "like"] do
    if is_binary(n[:post_id]) and viewer != nil, do: ~p"/#{viewer}/posts/#{n.post_id}"
  end

  defp primary_target(%{kind: "endorsement"}, viewer) when viewer != nil,
    do: ~p"/#{viewer}/tags"

  defp primary_target(_n, _viewer), do: nil

  defp actor_target(n) do
    if is_binary(n[:actor_param]), do: ~p"/#{n.actor_param}"
  end

  # The event text for the ungrouped kinds, rendered from the kind (not
  # stored) so it translates with the viewer's locale. Unknown kinds fall
  # back to the pushed text.
  defp notification_text(%{kind: "reply"}), do: gettext("replied to your post.")

  defp notification_text(%{kind: "organization_role"} = n) do
    case n[:role] do
      "owner" ->
        gettext("made you an owner of %{organization}.", organization: n.organization_name)

      "admin" ->
        gettext("made you an admin of %{organization}.", organization: n.organization_name)

      "recruiter" ->
        gettext("made you a recruiter for %{organization}.", organization: n.organization_name)

      _ ->
        gettext("gave you a role at %{organization}.", organization: n.organization_name)
    end
  end

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

  # The AI image scan removed an image. No actor (it was the machine); the
  # what-was-removed wording shares its single source with the email
  # (VutuvWeb.UserHelpers.image_kind_label/2).
  defp notification_text(%{kind: "image_rejected"} = n) do
    what = UserHelpers.image_kind_label(n[:image_kind], Gettext.get_locale(VutuvWeb.Gettext))

    gettext(
      "Our automated image review removed %{what}. Only family-friendly images suitable for a work environment are allowed.",
      what: what
    )
  end

  # Reporter protection: the actor is the *reported* member, rendered as
  # @handle by the actor line; the text explains the both-ways pause and
  # that an unfounded ruling undoes it.
  defp notification_text(%{kind: "report_protection"} = n) do
    case n[:status] do
      "restored" ->
        gettext(
          "Our admins found your report unfounded; the paused connection between you two is restored."
        )

      _ ->
        gettext(
          "Your report paused the connection between you two - no contact in either direction for now. If our admins find the report unfounded, this is undone."
        )
    end
  end

  # A handle change: show the old and new handle so the reader sees exactly
  # what was rewritten in their posts (before/after).
  defp notification_text(%{kind: "handle_change"} = n) do
    gettext("changed their handle from @%{old} to @%{new}.",
      old: n.old_handle,
      new: n.new_handle
    )
  end

  # New CV entries the author chose to announce (issue #980). A lone entry
  # gets the section-specific wording, so a reader can tell a job from a
  # degree without opening it; a group of them is counted and listed below.
  defp notification_text(%{kind: "cv_update", entries: [entry]}) do
    case entry.section do
      "educations" ->
        gettext("added a new education entry to their CV: %{entry}",
          entry: cv_entry_label(entry)
        )

      "qualifications" ->
        gettext("added a new certificate to their CV: %{entry}", entry: cv_entry_label(entry))

      _ ->
        gettext("added a new position to their CV: %{entry}", entry: cv_entry_label(entry))
    end
  end

  defp notification_text(%{kind: "cv_update"} = n) do
    gettext("added %{count} new entries to their CV:",
      count: compact_count(n[:entry_count] || 0)
    )
  end

  defp notification_text(n), do: n[:text]

  # "Head of Bridges · Span AG": what the entry is, then where. Either half
  # can be missing, so the separator only appears when both are there.
  defp cv_entry_label(entry) do
    [entry.title, entry.subtitle]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # One entry's own page under the author's profile.
  defp cv_entry_path(n, entry) do
    with slug when is_binary(slug) <- n[:actor_param],
         param when is_binary(param) <- entry.param do
      case entry.section do
        "work_experiences" -> ~p"/#{slug}/work_experiences/#{param}"
        "educations" -> ~p"/#{slug}/educations/#{param}"
        "qualifications" -> ~p"/#{slug}/qualifications/#{param}"
        _ -> ~p"/#{slug}"
      end
    else
      _ -> nil
    end
  end

  # How many of a group's entries are not in the shown list.
  defp cv_entries_more(n), do: (n[:entry_count] || 0) - length(n[:entries] || [])

  # ── Post previews ──

  # Reply and like notifications carry post ids the row can quote: a like the
  # liked post (`:post_id`), a reply both the recipient's own post that was
  # replied to (`:post_id`) and the reply itself (`:reply_post_id`). Look every
  # referenced post up in one batched, visibility-scoped query and attach a
  # preview map `%{post:, text:, truncated?:}` as `:post_preview` /
  # `:reply_preview`. Other kinds carry no ids, a photo-only post (empty body)
  # yields no preview, and a reply hidden from the viewer is absent from
  # `posts`, so all pass through unchanged.
  defp with_post_previews(entries, viewer) do
    posts =
      entries
      |> Enum.flat_map(&[&1[:post_id], &1[:reply_post_id] | List.wrap(&1[:post_ids])])
      |> then(&Posts.visible_posts_by_ids(viewer, &1))

    Enum.map(entries, fn entry ->
      entry
      |> put_preview(:post_preview, entry[:post_id], posts)
      |> put_preview(:reply_preview, entry[:reply_post_id], posts)
      |> put_change_previews(posts)
    end)
  end

  # A handle-change entry links the recipient's own posts that were rewritten:
  # the newest few as excerpt lines, with `handle_change_more/1` counting the
  # rest. `post_ids` are UUID v7, so a descending sort is newest-first.
  @change_preview_limit 5

  defp put_change_previews(%{kind: "handle_change", post_ids: post_ids} = entry, posts)
       when is_list(post_ids) do
    previews =
      post_ids
      |> Enum.sort(:desc)
      |> Enum.take(@change_preview_limit)
      |> Enum.map(&Map.get(posts, &1))
      |> Enum.filter(&match?(%Post{}, &1))
      |> Enum.map(&change_preview/1)

    Map.put(entry, :change_posts, previews)
  end

  defp put_change_previews(entry, _posts), do: entry

  defp change_preview(post) do
    case preview_excerpt(post.body) do
      %{} = excerpt -> Map.put(excerpt, :post, post)
      _ -> %{post: post, text: "", truncated?: false}
    end
  end

  # How many affected posts are not shown in the capped preview list.
  defp handle_change_more(%{post_ids: post_ids} = n) when is_list(post_ids),
    do: length(post_ids) - length(n[:change_posts] || [])

  defp handle_change_more(_), do: 0

  defp put_preview(entry, key, post_id, posts) do
    with true <- is_binary(post_id),
         %Post{} = post <- Map.get(posts, post_id),
         %{} = excerpt <- preview_excerpt(post.body) do
      Map.put(entry, key, Map.put(excerpt, :post, post))
    else
      _ -> entry
    end
  end

  # How many source lines and characters the notification quote keeps.
  @preview_line_count 3
  @preview_char_limit 280

  # The plain-text excerpt shown under a reply/like notification: the post's
  # first three non-empty lines, capped so one very long line can't blow the
  # row up. Kept server-side (not only a CSS clamp) so a hidden reply's body
  # never reaches the DOM.
  defp preview_excerpt(body) do
    lines =
      body
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {shown, rest} = Enum.split(lines, @preview_line_count)
    text = Enum.join(shown, "\n")

    cond do
      text == "" -> nil
      String.length(text) > @preview_char_limit -> %{text: clamp(text), truncated?: true}
      true -> %{text: text, truncated?: rest != []}
    end
  end

  defp clamp(text), do: text |> String.slice(0, @preview_char_limit) |> String.trim_trailing()
end
