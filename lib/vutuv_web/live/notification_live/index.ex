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
      URL (`?filter=`), patched without a reload. A press **paints itself**
      rather than waiting for the answer: the bar is `data-filter-bar="track"`,
      each tab `data-filter-tab`, and the whole list `data-filter-list` inside
      the column's `data-filter-scope` — the shared in-flight rules in
      `app.css` do the rest, off the `phx-click-loading` LiveView puts on a
      pressed patch link. Without it a slow line shows nothing at all between
      the press and a page of rows arriving, which reads as a dead control.
    * A rail (right column on md+, below the list on phones) offers **Follow
      back** suggestions (recent followers, reload-free follow via
      `Vutuv.Social`) and a **Last 30 days** summary
      (`Vutuv.Activity.activity_summary/2`).
    * A post a row quotes (the liked post, the reply) is **formatted the way
      /feed formats a post** - rendered from its Markdown source through
      `VutuvWeb.Markdown` into the `.markdown markdown--post` body recipe, so
      bold, lists, links, @mentions and #hashtags read as themselves instead of
      as source markers. It is cut to the reader's own line budget -
      `Vutuv.Accounts.User.notification_post_lines/1`, the
      `:notification_post_lines` preference: server-side to that many source
      lines, and visually by the `.notif-clamp` CSS clamp fed through the
      inline `--notif-clamp` custom property. The compact one-line contexts (a
      reply's "Your post:" breadcrumb, the handle-change list) sit inside the
      row's own link, so they cannot carry links of their own: those are
      flattened to plain text by `VutuvWeb.Markdown.to_plain_text/1` instead.

  The page is **numbered** (`?page=`), not an endless list: both the page and
  the filter live in the URL, so a page can be linked to and the back button
  works, and both are patched without a reload. `Vutuv.Activity` walks the
  merged feed by offset for it (`page:`), and `notifications_count/2` gives the
  pager its total under the same filter. The first page renders on the
  **static** mount too (issue #919), so the list is in the first HTTP paint.

  Live events arrive over `Vutuv.Activity` (PubSub `"user:<id>"`) and merge into
  their group, but only while the reader is on page 1 - an older page is a
  fixed window into the past and must not shift under them. Because grouping is
  a pure function over the retained item list, every change (paging, live push,
  the DayClock's midnight rollover) simply recomputes the sections - there is no
  stream to patch in place.
  """
  use VutuvWeb, :live_view

  import VutuvWeb.UserHTML, only: [user_row: 1]

  # What a notification says and where it leads, shared with the browser
  # notification ShellLive raises for the same event (issue #1249).
  import VutuvWeb.NotificationLine,
    only: [
      cv_entry_label: 1,
      cv_entry_path: 2,
      fediverse_reaction_text: 2,
      notification_target: 2,
      notification_text: 1,
      thread_text: 1
    ]

  # Like the feed and messages: not a page for anonymous visitors —
  # redirect to /login instead of rendering an empty 200.
  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.Fediverse
  alias Vutuv.Pages
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Social
  alias Vutuv.ViewerClock
  alias VutuvWeb.Live.MountHandoff
  alias VutuvWeb.Markdown
  alias VutuvWeb.NotificationLive.Groups
  alias VutuvWeb.UserHelpers

  @page_size 50
  @summary_days 30
  @follow_back_limit 5

  # The filter tabs: each maps to the event kinds `notifications_page`'s
  # `kinds:` option keeps. "all" passes nil (every source).
  #
  # Every kind in `Vutuv.Activity.kinds/0` must appear under exactly one tab, or
  # it is unreachable from the tabs AND `filtered_out?/2` drops it from the live
  # push for any reader not on "All" — which is what happened to
  # `reference_check`. `notification_filter_coverage_test.exs` fails the build
  # when the two lists drift apart again.
  @filters %{
    "all" => nil,
    "posts" => ~w(reply thread mention like fediverse_reply fediverse_reaction),
    "people" => ~w(follower connection endorsement),
    "other" =>
      ~w(organization_role moderation image_rejected report_protection handle_change cv_update
         username reference_check)
  }

  @doc false
  def filters, do: @filters

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # The previous visit's read marker - what "new since your last visit"
    # highlights - and its badge count, both captured *before* this visit
    # advances the marker below.
    read_marker = user.notifications_read_at
    new_count = if connected?(socket), do: Activity.unread_notification_count(user), else: 0

    # The rows the member already acknowledged one by one, from the browser
    # notifications they clicked — captured here for the same reason as the
    # marker above: `mark_notifications_read/1` drops them a line further down,
    # and this visit should still show them as read rather than as news.
    dismissed = Activity.dismissed_event_ids(user.id)

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
     |> assign(:dismissed, dismissed)
     |> assign(:today, ViewerClock.today())
     |> assign(:quote_lines, User.notification_post_lines(user))
     |> assign_rail(connected?(socket))}
  end

  # Both the filter (?filter=posts) and the page (?page=3) live in the URL, so
  # the tabs and the pager are patch links and the back button works; an
  # unknown filter falls back to "all", an unparseable page to 1. Runs on both
  # the static and the connected mount, so the page is in the first HTTP paint
  # (issue #919).
  @impl true
  def handle_params(params, _uri, socket) do
    filter = if Map.has_key?(@filters, params["filter"]), do: params["filter"], else: "all"

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:page, Pages.page_param(params))
     |> load_page()}
  end

  # The rail's "Follow back" pill (user_row live?): follow with no reload,
  # then recompute the rail so the new followee drops out.
  @impl true
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
      # `Activity.notify/2` gives a push the same id its derived row will have,
      # so an event that arrives twice (a CV sitting growing, a reconnect)
      # replaces the row an open page already shows instead of stacking
      # another. Only a kind with no source row behind it falls through to a
      # minted id outside that namespace.
      |> Map.put_new(:id, "live-#{System.unique_integer([:positive, :monotonic])}")

    cond do
      # Not part of what this tab shows: it belongs to neither the list nor
      # the tab's total.
      filtered_out?(item, socket.assigns.filter) ->
        {:noreply, socket}

      # An older page is a fixed window into the past: merging a brand-new
      # event into it would show it out of order and push everything below it
      # down by one. Only the total grows, so the event is on page 1 the next
      # time the reader loads it.
      socket.assigns.page > 1 ->
        {:noreply, update(socket, :total, &(&1 + 1))}

      true ->
        [item] = with_post_previews([item], socket.assigns.current_user)

        {:noreply,
         socket
         |> update(:items, fn items ->
           [item | Enum.reject(items, &(&1.id == item.id))] |> Enum.take(@page_size)
         end)
         |> update(:total, &(&1 + 1))
         |> assign_sections()}
    end
  end

  # The reader's day may have rolled over (Vutuv.DayClock ticks hourly):
  # recompute the sections so "Today" becomes "Yesterday" without a reload.
  def handle_info(:day_changed, socket) do
    {:noreply, socket |> assign(:today, ViewerClock.today()) |> assign_sections()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # One numbered page of the feed under the active filter, plus the filtered
  # total the pager windows over. Both are one query per source / one query in
  # total, and both run on the static mount as well: the pager is part of the
  # page, so a no-JS visitor and the first paint must carry it. The static
  # pass stashes what it computed and the connected mount's handle_params —
  # moments later, same viewer, same URL — takes it instead of re-running the
  # same queries (`VutuvWeb.Live.MountHandoff`). The subject carries the
  # filter and the *requested* page, so a patch to another tab or page can
  # never reuse a stale stash; any miss (expired, consumed, a patch, a
  # reconnect) falls back to the plain full load. The visit's mark-read write
  # lives in mount, not here, so the handoff leaves it at exactly once.
  defp load_page(socket) do
    viewer_id = socket.assigns.current_user.id
    subject = {:notifications, socket.assigns.filter, socket.assigns.page}

    if connected?(socket) do
      case MountHandoff.take(viewer_id, subject) do
        {:ok, payload} -> apply_page(socket, payload)
        :error -> apply_page(socket, page_payload(socket))
      end
    else
      payload = page_payload(socket)
      MountHandoff.stash(viewer_id, subject, payload)
      apply_page(socket, payload)
    end
  end

  # Everything one page load computes, as data — what the dead render hands
  # the connected mount through the single-use stash. A payload map rather
  # than an assigns diff because :page is corrected here (a ?page= past the
  # end falls back), and a diff against the pre-existing raw value would lose
  # that correction on the connected side.
  defp page_payload(socket) do
    user = socket.assigns.current_user
    kinds = @filters[socket.assigns.filter]

    # The total comes first: a ?page= past the end falls back to page 1 (the
    # same fallback Vutuv.Pages gives every browse page), so the rows shown and
    # the page the pager marks current can never disagree.
    total = Activity.notifications_count(user.id, kinds)
    page = Pages.effective_page(%{"page" => socket.assigns.page}, total, @page_size)

    feed = Activity.notifications_page(user.id, limit: @page_size, kinds: kinds, page: page)

    %{
      page: page,
      total: total,
      items:
        feed.entries
        |> with_seen_flags(user, socket.assigns.dismissed)
        |> with_post_previews(user)
    }
  end

  defp apply_page(socket, payload) do
    socket
    |> assign(payload)
    |> assign_sections()
  end

  # Rows the reader has already dealt with out in the feed: they answered,
  # liked, bookmarked or reposted the post the row is about, so
  # `Vutuv.Activity.mark_post_seen/2` recorded it and the shell's badge stopped
  # counting it. They stay listed — the page is the log of what happened — they
  # just no longer render as new, so the list and the badge tell one story. One
  # query per page.
  defp with_seen_flags(entries, viewer, dismissed) do
    seen =
      entries
      |> Enum.map(&Activity.subject_post_id/1)
      |> Enum.reject(&is_nil/1)
      |> then(&Activity.seen_post_ids(viewer.id, &1))

    Enum.map(entries, fn entry ->
      read? =
        MapSet.member?(seen, Activity.subject_post_id(entry)) or
          MapSet.member?(dismissed, entry[:id])

      Map.put(entry, :seen?, read?)
    end)
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

  # The id of the day's first "thread" group, so its row alone carries the
  # opt-out hint (issue #1025) - one hint per Berlin-day section, not per row.
  # nil when the day has no thread row, so nothing is marked.
  defp first_thread_group_id(groups) do
    Enum.find_value(groups, fn group -> group.kind == "thread" && group.id end)
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
        <%!-- `data-filter-scope` pairs the tabs with the list they replace: the
        in-flight paint in `app.css` dims every `[data-filter-list]` inside this
        container while one of its tabs is waiting for an answer, so both
        markers have to stay under this one element. --%>
        <div data-filter-scope class="min-w-0 md:col-span-2">
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">
              {gettext("Notifications")}
            </h1>
            <p :if={@new_count > 0} id="new-count" class="mb-0 text-sm font-semibold text-accent">
              {new_count_label(@new_count)}
            </p>
          </div>

          <%!-- `data-filter-bar="track"` picks which of the app's two tab looks
          the in-flight paint reaches for: here the white pill on a filled
          trough, so a pressed tab turns into this bar's own active tab rather
          than into the brand pill the post filter tabs wear. --%>
          <div
            id="notification-filter"
            data-filter-bar="track"
            class="mt-4 flex gap-1 overflow-x-auto rounded-lg bg-slate-100 p-1 text-sm dark:bg-slate-800"
          >
            <.link
              :for={{value, label} <- filter_options()}
              patch={filter_path(value)}
              data-filter-tab={value}
              aria-current={@filter == value && "page"}
              class={filter_tab_class(@filter == value)}
            >
              {label}
            </.link>
          </div>

          <%!-- Everything a tab replaces lives in one `data-filter-list`, so the
          shared paint can dim it while the answer is on its way. The tabs stay
          outside it: the reader has to keep seeing which one they pressed. --%>
          <div data-filter-list>
            <section :for={section <- @sections} data-day-section>
              <h2
                class="mb-0 mt-6 text-sm font-semibold uppercase tracking-wide text-slate-500"
                data-day-heading
              >
                {day_label(section.day, @today)}
              </h2>
              <% first_thread_id = first_thread_group_id(section.groups) %>
              <div class="mt-2 divide-y divide-slate-100 overflow-hidden rounded-2xl bg-white shadow-sm ring-1 ring-slate-200 dark:divide-slate-800 dark:bg-slate-900 dark:ring-slate-800">
                <.notification_row
                  :for={group <- section.groups}
                  group={group}
                  current_user={@current_user}
                  quote_lines={@quote_lines}
                  thread_hint={group.kind == "thread" and group.id == first_thread_id}
                />
              </div>
            </section>

            <p :if={@empty?} class="mt-6 text-slate-600 dark:text-slate-400">
              {gettext("Nothing new yet.")}
            </p>

            <%!-- Numbered pages, patched over the socket: the page rides the URL
            beside the filter, so it survives a reload and the back button. --%>
            <.pager
              params={%{"page" => @page}}
              total={@total}
              per_page={page_size()}
              path={~p"/notifications"}
              query={pager_query(@filter)}
            />
          </div>
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

  # The page size, as a function: inside ~H a bare `@page_size` would read the
  # assigns, not the module attribute.
  defp page_size, do: @page_size

  # The pager carries the active tab onto every page link, so paging inside a
  # filtered feed stays in that filter. "all" is the default and needs no param.
  defp pager_query("all"), do: %{}
  defp pager_query(filter), do: %{"filter" => filter}

  # ── One grouped row ──

  attr(:group, :map, required: true)
  attr(:current_user, :any, required: true)
  attr(:quote_lines, :integer, required: true)
  attr(:thread_hint, :boolean, default: false)

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
          <%= cond do %>
            <%!-- The one row that is not a single link: see username_line/1. --%>
            <% @group.kind == "username" -> %>
              <.username_line handle={@n.username} />
            <% target -> %>
              <.link href={target} class="hover:text-brand-700 hover:underline dark:hover:text-brand-300">
                {group_text(@group)}
              </.link>
            <% true -> %>
              {group_text(@group)}
          <% end %>
        </p>

        <%!-- A like quotes the liked post once, formatted like a feed post and
        cut to the reader's line budget (:notification_post_lines). --%>
        <.quoted_post
          :if={@group.kind == "like" and @n[:post_preview]}
          id={"quote-#{@group.id}"}
          href={~p"/#{@current_user}/posts/#{@n.post_id}"}
          html={@n.post_preview.html}
          quote_lines={@quote_lines}
          class="mt-1.5"
        />

        <%!-- A mention quotes the post that named the reader. Its permalink
        lives under the post's own author, not under the reader — and that
        author may be an organization (issue #1334), so it is asked of
        `Posts.path/1` rather than assembled here from a member handle. --%>
        <.quoted_post
          :if={@group.kind == "mention" and @n[:post_preview]}
          id={"quote-#{@group.id}"}
          href={Posts.path(@n.post_preview.post)}
          html={@n.post_preview.html}
          quote_lines={@quote_lines}
          class="mt-1.5"
        />

        <%!-- A reply quotes the reply itself, under a one-line breadcrumb naming
        the recipient's own post it answers. A thread event carries no post of
        the recipient's, so there only the reply quotes. --%>
        <div
          :if={@group.kind in ["reply", "thread"] and (@n[:post_preview] || @n[:reply_preview])}
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
          <.quoted_post
            :if={@n[:reply_preview]}
            id={"quote-reply-#{@group.id}"}
            data-reply-preview="true"
            href={Posts.path(@n.reply_preview.post)}
            html={@n.reply_preview.html}
            quote_lines={@quote_lines}
          />
        </div>

        <%!-- A reply from another network quotes its text (issue #1069). Plain
        text, clamped like the other quotes and deliberately NOT run through the
        Markdown renderer: a stranger's words must not be able to mint links,
        least of all @mention links into local profiles. A private reply
        (issue #1071) says so, since the member has to know that before they
        answer. --%>
        <div :if={@group.kind == "fediverse_reply" and @n[:note_text]} class="mt-1.5 space-y-1">
          <p
            :if={@n[:note_audience] && @n.note_audience != "public"}
            data-remote-private
            class="mb-0 text-xs font-medium text-slate-600 dark:text-slate-400"
          >
            <span aria-hidden="true">🔒</span> {gettext("Sent to you only, visible to nobody else")}
          </p>
          <%!-- The same solid quote rail the local reply quotes wear — the row's
          wording already says it came from another network, so the quote needs
          no dashed variant of its own. Marked for the clamp measurement like
          those quotes too, so a remote reply that runs past the reader's line
          budget also ends in a "…".

          And it is a link, on the same stretched-overlay arrangement as
          <.quoted_post>: a readable block of somebody's words is what the reader
          reaches for, so a quote that does nothing on tap reads as a broken row,
          whichever network the words came from. It goes where the row's own
          sentence already goes (`primary_target/2` — the reader's post, not the
          stranger's server, which the card over there links to) and carries the
          note's anchor, so a post that collected several replies opens on this
          one. No `[&_a]:relative` escape hatch is needed inside: unlike a local
          quote's Markdown, this text is deliberately never linkified, so there
          is no inner link for the overlay to swallow. --%>
          <div
            id={"quote-remote-#{@group.id}"}
            phx-hook="PostPreviewClamp"
            data-post-preview
            data-remote-reply-preview="true"
            class={[
              "relative border-l-2 border-slate-200 pl-2.5 transition-colors hover:border-brand-400",
              "dark:border-slate-700 dark:hover:border-brand-500"
            ]}
          >
            <.link
              href={remote_reply_target(@n, @current_user)}
              aria-label={gettext("View the conversation")}
              class="absolute inset-0 z-10"
            >
            </.link>
            <%!-- No `text-*` / `leading-*` here: `.notif-clamp` owns the type
            size and line height, since its box height is counted in them. --%>
            <p
              data-clamp-body
              class="notif-clamp mb-0 whitespace-pre-line text-slate-600 dark:text-slate-400"
              {clamp_attrs(@quote_lines)}
            >{@n.note_text}</p>
          </div>
        </div>

        <%!-- The day's first thread row says why it is here and links to the
        switch that stops it (issue #1025), once per day so it stays a hint and
        not a banner. It shows only when thread events reach this reader, which
        is exactly when the switch is still on. --%>
        <p
          :if={@thread_hint}
          data-thread-hint
          class="mb-0 mt-1.5 text-xs text-slate-500 dark:text-slate-400"
        >
          {gettext("You wrote in this thread.")}
          <.link
            href={~p"/settings/notifications"}
            class="font-medium text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
          >
            {gettext("Turn off thread notifications")} ›
          </.link>
        </p>

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

  # The post a row quotes, formatted exactly the way /feed formats a post: the
  # rendered Markdown in the `.markdown markdown--post` body recipe (headings
  # flattened to bold, @mentions and #hashtags linked), clipped by `.notif-clamp`
  # to the reader's line budget.
  #
  # It is a block with a *stretched* permalink link rather than one big `<a>`,
  # because a formatted body carries links of its own and an `<a>` inside an
  # `<a>` is invalid: the prose falls through to the stretched link, so a click
  # anywhere still opens the post, while a mention/hashtag/URL keeps its own
  # target. The feed's "Suggested posts" rail is arranged the same way.
  # `id` is what lets the clamp measurement re-run after a patch: the row is
  # marked `data-post-preview` and the body `data-clamp-body`, the same pair the
  # feed's post previews use, so app.js measures the quote and sets `is-clamped`
  # on the wrapper — which is what paints the "…" that says the quote goes on
  # (see the excerpt-clamp block in components.css). Whether the reader's line
  # budget was enough depends on column width and font, so only the browser can
  # decide it.
  attr(:id, :string, required: true)
  attr(:href, :string, required: true)
  attr(:html, :any, required: true)
  attr(:quote_lines, :integer, required: true)
  attr(:class, :string, default: nil)
  attr(:rest, :global)

  defp quoted_post(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="PostPreviewClamp"
      data-post-preview
      class={[
        "relative border-l-2 border-slate-200 pl-2.5 transition-colors hover:border-brand-400",
        "dark:border-slate-700 dark:hover:border-brand-500",
        @class
      ]}
      {@rest}
    >
      <.link href={@href} aria-label={gettext("View post")} class="absolute inset-0 z-10"></.link>
      <%!-- The type size and line height come from `.notif-clamp` itself: the
      reader's line budget is a box height counted in them, so a `text-*` here
      would cut the quote mid-letter. --%>
      <div
        data-clamp-body
        class="markdown markdown--post notif-clamp text-slate-600 dark:text-slate-400 [&_a]:relative [&_a]:z-20"
        {clamp_attrs(@quote_lines)}
      >
        {@html}
      </div>
    </div>
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
    <%= cond do %>
      <% @actor.param -> %>
        <%!-- `actor_path/1`, never `~p"/#{@actor.param}"`: a page's param is a
        slug under /organizations/:slug, and the root belongs to member handles
        (issue #1336). This is the second link on the row and the one that is
        easy to miss — `actor_target/1` below covers the row's own href. --%>
        <.link
          href={actor_path(@actor)}
          class="font-semibold text-slate-900 hover:text-brand-700 dark:text-white dark:hover:text-brand-300"
        >{@actor.name}</.link>
      <% @actor[:url] -> %>
        <%!-- Somebody on another network (issue #1069). There is no vutuv
        profile behind the name, so it links out to their account and the
        `@handle@host` beside it says which network answered. --%>
        <a
          href={@actor.url}
          target="_blank"
          rel="nofollow noopener noreferrer"
          class="font-semibold text-slate-900 hover:text-brand-700 dark:text-white dark:hover:text-brand-300"
        >{@actor.name}</a><span
          :if={@actor[:handle] && @actor.handle != @actor.name}
          class="text-xs font-normal text-slate-600 dark:text-slate-400"
        > {@actor.handle}</span>
      <% true -> %>
        <span class="font-semibold">{@actor.name}</span>
    <% end %>
    """
  end

  # The welcome note is the one row that is NOT one big link: the handle points
  # at the member's own profile and the two URLs at the pages they name, so
  # every destination is reachable and the rest of the sentence stays plain
  # text. The three `{markers}` are split out of the translation (split_marker/2,
  # total by design, so a botched .po can never raise here) and each piece
  # rendered in its own place — which is also how German and English each get
  # their natural word order.
  #
  # It greets first and explains second. It used to open with "Your
  # automatically assigned vutuv username is …", which leads with a machine
  # detail on the first thing a new member ever reads from us. The import offer
  # rides along because this is the one moment somebody arriving from LinkedIn
  # still has that profile in mind, and the page is otherwise buried in
  # /settings.
  #
  # NEITHER language may end this sentence on a URL: the full stop then sits
  # flush against the address, and a reader cannot tell whether it belongs to
  # the link (reported 2026-08-04). Both {url} and {import_url} are therefore
  # followed by a space and at least one word. Keep that property when
  # rewording, in the .po files too.
  attr(:handle, :string, required: true)

  defp username_line(assigns) do
    {greeting, rest} =
      split_marker(
        gettext(
          "Welcome to vutuv! You can change your username {handle} at {url}, and at {import_url} you can import an existing LinkedIn profile."
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

  # The row's clock time: sections are the reader's calendar days, so the
  # visible time is their own wall clock in their own region (like post
  # stamps); the <time> keeps an unambiguous ISO-8601 UTC datetime for
  # machines. Server-rendered final - deliberately no data-localtime rewrite.
  attr(:at, :any, required: true)

  defp row_time(assigns) do
    utc = DateTime.from_naive!(assigns.at, "Etc/UTC")

    assigns =
      assigns
      |> assign(:datetime, DateTime.to_iso8601(utc))
      |> assign(:title, ViewerClock.format(utc, :datetime))
      |> assign(:clock, ViewerClock.format(utc, :time))

    ~H"""
    <time datetime={@datetime} title={@title} class="text-xs tabular-nums text-slate-500">
      {@clock}
    </time>
    """
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
  @brand_kinds ~w(follower reply thread mention connection report_protection organization_role handle_change cv_update fediverse_reply fediverse_reaction)

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
  # A reply elsewhere in a thread the recipient writes in.
  defp kind_glyph("thread"), do: "⤷"
  # Being named by @handle. Shares the glyph with the (rare, "More"-tab)
  # handle-change kind: both are about a handle, and the badge's title/sr-only
  # label tells them apart where the glyph alone would not.
  defp kind_glyph("mention"), do: "@"
  defp kind_glyph("like"), do: "♥"
  # A reply written on another network (issue #1069) — the same globe the
  # post card's "from other networks" line uses, so one glyph means one thing.
  defp kind_glyph("fediverse_reply"), do: "🌐"
  # A favourite or a re-share from out there (issue #1068) — same globe, since
  # "this came from another network" is the one thing the glyph has to say; the
  # sentence beside it names the verb.
  defp kind_glyph("fediverse_reaction"), do: "🌐"
  # "connection" is the vernetzt (mutual-follow) event; the handshake glyph.
  defp kind_glyph("connection"), do: "🤝"
  defp kind_glyph("moderation"), do: "⚑"
  defp kind_glyph("image_rejected"), do: "🖼"
  defp kind_glyph("report_protection"), do: "🛡"
  defp kind_glyph("organization_role"), do: "🏢"
  defp kind_glyph("handle_change"), do: "@"
  defp kind_glyph("cv_update"), do: "📄"
  # The welcome note naming the member's own handle.
  defp kind_glyph("username"), do: "👋"
  # The finished AI reading of an Arbeitszeugnis. The magnifier, not a robot:
  # what arrived is a close reading of wording, and the member is being told to
  # go and read it.
  defp kind_glyph("reference_check"), do: "🔍"
  defp kind_glyph(_), do: "•"

  # The accessible kind name (the badge's title + sr-only text). Translated
  # like the row text; raw kind strings ("cv_update") must not leak to users.
  defp kind_label("follower"), do: gettext("Follower")
  defp kind_label("endorsement"), do: gettext("Endorsement")
  defp kind_label("reply"), do: gettext("Reply")
  defp kind_label("thread"), do: gettext("Thread reply")
  defp kind_label("mention"), do: gettext("Mention")
  defp kind_label("like"), do: gettext("Like")
  defp kind_label("fediverse_reply"), do: gettext("Reply from another network")
  defp kind_label("fediverse_reaction"), do: gettext("Reaction from another network")
  defp kind_label("connection"), do: gettext("Connection")
  defp kind_label("moderation"), do: gettext("Moderation")
  defp kind_label("image_rejected"), do: gettext("Image review")
  defp kind_label("report_protection"), do: gettext("Report protection")
  defp kind_label("organization_role"), do: gettext("Organization role")
  defp kind_label("handle_change"), do: gettext("Handle change")
  defp kind_label("cv_update"), do: gettext("CV update")
  defp kind_label("username"), do: gettext("Username")
  defp kind_label("reference_check"), do: gettext("Employment reference review")
  defp kind_label(_), do: gettext("Activity")

  # ── The sentence ──

  # The grouped sentence tail after the actor names. Only the forms that differ
  # from the single-actor one are spelled here - German conjugates the
  # follower/connection verbs across the count where English does not, hence
  # the count-branched msgids. Everything else falls through to
  # VutuvWeb.NotificationText, which the browser notification shares, so one
  # event cannot read differently in the two places (issue #1249).
  defp group_text(%{kind: "follower", actor_count: count}) when count > 1,
    do: gettext("are now following you.")

  defp group_text(%{kind: "connection", actor_count: count}) when count > 1,
    do: gettext("are now connected with you.")

  defp group_text(%{kind: "endorsement", tags: [tag]}),
    do: notification_text(%{kind: "endorsement", tag: tag})

  defp group_text(%{kind: "endorsement", tags: [_ | _] = tags}),
    do: gettext("endorsed you for %{tags}.", tags: join_names(tags))

  defp group_text(%{kind: "thread", actor_count: count}), do: thread_text(count)

  defp group_text(%{kind: "fediverse_reaction", actor_count: count, item: item}),
    do: fediverse_reaction_text(item[:reaction_kind], count)

  defp group_text(%{item: item}), do: notification_text(item)

  # "Elixir, Phoenix and Rails" - all but the last joined by commas, the last
  # by the localized joining word.
  defp join_names([single]), do: single

  defp join_names(names) do
    {front, [last]} = Enum.split(names, -1)
    Enum.join(front, ", ") <> " " <> gettext("and") <> " " <> last
  end

  # Where the quoted remote reply itself goes: the same conversation the row's
  # sentence opens, plus the anchor of this note (`Fediverse.reply_anchor/1`),
  # so a post that collected several replies lands on the one being quoted
  # rather than at the top. The anchor is dropped when the row somehow carries
  # no note id, which leaves the plain conversation link rather than a dead "#".
  defp remote_reply_target(n, viewer) do
    target = notification_target(n, viewer)

    case n[:note_id] do
      id when is_binary(id) and is_binary(target) -> target <> "#" <> Fediverse.reply_anchor(id)
      _ -> target
    end
  end

  # The same decision for the grouped-actor shape, whose keys are `kind` /
  # `param` rather than the row's `actor_*`. One function per shape, both
  # branching on the kind, so neither can be the one that forgets.
  defp actor_path(%{kind: "organization", param: slug}) when is_binary(slug),
    do: ~p"/organizations/#{slug}"

  defp actor_path(%{param: param}), do: ~p"/#{param}"

  # How many of a group's entries are not in the shown list.
  defp cv_entries_more(n), do: (n[:entry_count] || 0) - length(n[:entries] || [])

  # ── Post previews ──

  # Reply and like notifications carry post ids the row can quote: a like the
  # liked post (`:post_id`), a reply both the recipient's own post that was
  # replied to (`:post_id`) and the reply itself (`:reply_post_id`). Look every
  # referenced post up in one batched, visibility-scoped query and attach a
  # preview map (`%{post:, html:}` or `%{post:, text:}`, see `render_excerpt/3`)
  # as `:post_preview` / `:reply_preview`. Other kinds carry no ids, a post with
  # no text (a photo-only one) yields no preview, and a reply hidden from the
  # viewer is absent from `posts`, so all pass through unchanged.
  defp with_post_previews(entries, viewer) do
    posts =
      entries
      |> Enum.flat_map(&[&1[:post_id], &1[:reply_post_id] | List.wrap(&1[:post_ids])])
      |> then(&Posts.visible_posts_by_ids(viewer, &1))

    lines = User.notification_post_lines(viewer)

    Enum.map(entries, fn entry ->
      entry
      |> put_preview(:post_preview, entry[:post_id], posts, lines, quoted_form(entry))
      |> put_preview(:reply_preview, entry[:reply_post_id], posts, lines, :html)
      |> put_change_previews(posts, lines)
    end)
  end

  # A reply row shows the recipient's own post only as the one-line breadcrumb
  # above the reply it quotes in full, so that one is flattened to text. Every
  # other quoted post is rendered formatted. Deciding here (rather than building
  # both forms) keeps a page of 50 rows off the Markdown renderer's DB lookups
  # for bodies nothing will show formatted.
  defp quoted_form(%{kind: "reply"}), do: :text
  defp quoted_form(_entry), do: :html

  # A handle-change entry links the recipient's own posts that were rewritten:
  # the newest few as excerpt lines, with `handle_change_more/1` counting the
  # rest. `post_ids` are UUID v7, so a descending sort is newest-first.
  @change_preview_limit 5

  defp put_change_previews(%{kind: "handle_change", post_ids: post_ids} = entry, posts, lines)
       when is_list(post_ids) do
    previews =
      post_ids
      |> Enum.sort(:desc)
      |> Enum.take(@change_preview_limit)
      |> Enum.map(&Map.get(posts, &1))
      |> Enum.filter(&match?(%Post{}, &1))
      |> Enum.map(&change_preview(&1, lines))

    Map.put(entry, :change_posts, previews)
  end

  defp put_change_previews(entry, _posts, _lines), do: entry

  defp change_preview(post, lines) do
    case preview_excerpt(post.body, lines, :text) do
      %{} = excerpt -> Map.put(excerpt, :post, post)
      _ -> %{post: post, text: ""}
    end
  end

  # How many affected posts are not shown in the capped preview list.
  defp handle_change_more(%{post_ids: post_ids} = n) when is_list(post_ids),
    do: length(post_ids) - length(n[:change_posts] || [])

  defp handle_change_more(_), do: 0

  defp put_preview(entry, key, post_id, posts, lines, form) do
    with true <- is_binary(post_id),
         %Post{} = post <- Map.get(posts, post_id),
         %{} = excerpt <- preview_excerpt(post.body, lines, form) do
      Map.put(entry, key, Map.put(excerpt, :post, post))
    else
      _ -> entry
    end
  end

  # How many characters one kept line may contribute. A source line wraps to
  # several rendered ones, so the character budget scales with the reader's
  # line count and keeps one very long line from shipping a whole essay into
  # the row.
  @preview_chars_per_line 100

  # An inline image reference (`![alt](url)`) in the Markdown source. The quote
  # is text-only, so it is dropped before the line budget is spent - otherwise a
  # picture nobody sees would eat a line of it, and a post that is nothing but a
  # picture would quote an empty box.
  @inline_image ~r/!\[[^\]]*\]\([^)]*\)/

  # The excerpt shown under a reply/like notification: the post's first `lines`
  # non-empty lines (the reader's `:notification_post_lines` preference), cut
  # server-side (not only by the CSS clamp) so the rest of a quoted body never
  # reaches the DOM. Returns nil for a body with no text left to show.
  defp preview_excerpt(body, lines, form) do
    source =
      @inline_image
      |> Regex.replace(body, "")
      |> String.split("\n")
      |> take_source_lines(lines)

    case String.trim(source) do
      "" -> nil
      trimmed -> render_excerpt(trimmed, lines, form)
    end
  end

  # Keeps lines until `budget` non-empty ones are in, carrying the blank lines
  # between them along: they separate the Markdown blocks, and dropping them
  # would glue a list onto the paragraph above it.
  defp take_source_lines(source_lines, budget) do
    source_lines
    |> Enum.reduce_while({[], budget}, fn line, {kept, left} ->
      cond do
        String.trim(line) == "" -> {:cont, {[line | kept], left}}
        left > 1 -> {:cont, {[line | kept], left - 1}}
        true -> {:halt, {[line | kept], 0}}
      end
    end)
    |> then(fn {kept, _left} -> kept |> Enum.reverse() |> Enum.join("\n") end)
  end

  # The two shapes a quoted post is shown in.
  #
  # `:html` is the formatted rendering /feed gives a post, block-cut at the
  # character budget so one essay-long line still ships a small DOM. Images are
  # deliberately not passed: a quote is text.
  #
  # `:text` is the flattened one-line form the compact contexts use (the "Your
  # post:" breadcrumb above a reply, the handle-change list), where real HTML
  # would nest a link inside the row's own link - but the Markdown markers must
  # not show either, so it goes through the renderer as well.
  defp render_excerpt(source, lines, :html) do
    {html, _truncated?} = Markdown.render_preview(source, [], limit: char_budget(lines))
    %{html: html}
  end

  defp render_excerpt(source, lines, :text) do
    %{text: source |> Markdown.to_plain_text() |> clamp(char_budget(lines))}
  end

  defp char_budget(lines), do: lines * @preview_chars_per_line

  defp clamp(text, limit), do: text |> String.slice(0, limit) |> String.trim_trailing()

  # The reader's line budget as an inline CSS custom property for `.notif-clamp`
  # — splatted, so a reader on the shipped default (what the stylesheet's own
  # fallback says) adds no attribute at all and the DOM stays clean.
  defp clamp_attrs(lines) do
    if lines == User.notification_post_lines_default(),
      do: [],
      else: [style: "--notif-clamp:#{lines}"]
  end
end
