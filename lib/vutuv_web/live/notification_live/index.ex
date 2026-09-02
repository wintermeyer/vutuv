defmodule VutuvWeb.NotificationLive.Index do
  @moduledoc """
  Notifications page. The feed is real data derived at read time by
  `Vutuv.Activity.notifications_page/2` from the event tables that already
  exist, so it reaches back to events from before this page existed.

  Presentation (the 2026-09 card layout, replacing the 2026-07 rows):

    * Raw events are grouped **by subject** under **the reader's calendar
      days** by `VutuvWeb.NotificationLive.Groups`: everything about one post
      — likes, replies, mentions, answers deeper in its thread, and what other
      networks sent back — is one **post card** headed by the post itself (a
      two-line teaser, its first pictures or its link screenshot on the right,
      a count of what came back), followed by one line per verb: every reply
      keeps a line of its own carrying its words, likes and re-shares merge
      into one line each. The day's followers, connections and endorsements
      are one **people card**. Measured on the real feed before the change: 39
      events on one day were about 11 posts, and the verb-keyed rows showed
      the busiest post three times over.
    * A reply line **unfolds** on tap (`toggle_line`) into the reply formatted
      the way /feed formats a post (`<.quoted_post>`, cut to the reader's
      `:notification_post_lines`) plus a Reply link to its permalink; a card
      with more than `@card_lines` lines folds the rest behind "Show N more"
      (`unfold`). Both are socket round trips, so the dead render is exactly
      what the connected one starts from.
    * Within a day the cards with an **unanswered reply** come first, then the
      rest of what is new since the previous visit, then what the reader has
      seen — the page draws a "Seen before" rule at that transition. Unread is
      still the pre-visit read marker (tint + coral dot), and the visit still
      advances the marker and clears the shell's bell badge.
    * The **filter chips** (all / replies / reactions / people / more) count
      what is new since the last visit and restrict the feed server-side via
      `notifications_page`'s `kinds:` option; they live in the URL
      (`?filter=`), patched without a reload. A press **paints itself** rather
      than waiting for the answer: the bar is `data-filter-bar="track"`, each
      chip `data-filter-tab`, and the whole list `data-filter-list` inside the
      column's `data-filter-scope` — the shared in-flight rules in `app.css`
      do the rest, off the `phx-click-loading` LiveView puts on a pressed patch
      link.
    * The last 30 days are one line under the title
      (`Vutuv.Activity.activity_summary/2`); the rail (right column on md+,
      below the list on phones) keeps the **Follow back** suggestions (recent
      followers, reload-free follow via `Vutuv.Social`).

  The page is **numbered** (`?page=`), not an endless list: both the page and
  the filter live in the URL, so a page can be linked to and the back button
  works, and both are patched without a reload. `Vutuv.Activity` walks the
  merged feed by offset for it (`page:`), and `notifications_count/2` gives the
  pager its total under the same filter. The first page renders on the
  **static** mount too (issue #919), so the list is in the first HTTP paint.

  Live events arrive over `Vutuv.Activity` (PubSub `"user:<id>"`) and merge into
  their card, but only while the reader is on page 1 - an older page is a
  fixed window into the past and must not shift under them. Because grouping is
  a pure function over the retained item list, every change (paging, live push,
  the DayClock's midnight rollover) simply recomputes the sections - there is no
  stream to patch in place.
  """
  use VutuvWeb, :live_view

  import VutuvWeb.FediverseComponents, only: [remote_actor_link: 3]
  import VutuvWeb.UserHTML, only: [user_row: 1]

  # What a notification says and where it leads, shared with the browser
  # notification ShellLive raises for the same event (issue #1249).
  import VutuvWeb.NotificationLine,
    only: [
      cv_entry_label: 1,
      cv_entry_path: 2,
      notification_target: 2,
      notification_text: 1
    ]

  # Like the feed and messages: not a page for anonymous visitors —
  # redirect to /login instead of rendering an empty 200.
  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Note
  alias Vutuv.Pages
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Screenshot
  alias Vutuv.Social
  alias Vutuv.ViewerClock
  alias VutuvWeb.Live.MountHandoff
  alias VutuvWeb.Markdown
  alias VutuvWeb.NotificationLive.Groups
  alias VutuvWeb.PostComponents
  alias VutuvWeb.PostTeaser
  alias VutuvWeb.UserHelpers

  @page_size 50
  @summary_days 30
  @follow_back_limit 5

  # How many lines a card shows before folding the rest behind a count. Four
  # keeps a card with a dozen answers to the height of the busiest real one
  # (three replies and a like line) while a tap still reaches everything.
  @card_lines 4

  # The filter chips: each maps to the event kinds `notifications_page`'s
  # `kinds:` option keeps. "all" passes nil (every source).
  #
  # Every kind in `Vutuv.Activity.kinds/0` must appear under exactly one chip,
  # or it is unreachable from the chips AND `filtered_out?/2` drops it from the
  # live push for any reader not on "All" — which is what happened to
  # `reference_check`. `notification_filter_coverage_test.exs` fails the build
  # when the two lists drift apart again.
  @filters %{
    "all" => nil,
    "replies" => ~w(reply thread mention fediverse_reply),
    "reactions" => ~w(like fediverse_reaction),
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
    # highlights - and its per-chip badge counts, all captured *before* this
    # visit advances the marker below.
    read_marker = user.notifications_read_at
    new_counts = if connected?(socket), do: unread_counts(user), else: %{}

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
     |> assign(:new_counts, new_counts)
     |> assign(:dismissed, dismissed)
     |> assign(:today, ViewerClock.today())
     |> assign(:quote_lines, User.notification_post_lines(user))
     |> assign(:expanded, MapSet.new())
     |> assign(:unfolded, MapSet.new())
     |> assign_rail(connected?(socket))}
  end

  # Both the filter (?filter=replies) and the page (?page=3) live in the URL, so
  # the chips and the pager are patch links and the back button works; an
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

  # A reply line unfolds into the formatted quote and folds again on the next
  # tap. Kept per line id, so a live push or a midnight rollover that rebuilds
  # the sections leaves an open line open. The quote itself is rendered here,
  # on the unfold, not for every reply on the page: a full Markdown pass per
  # line was paid for fifty lines and shown for none until somebody tapped.
  def handle_event("toggle_line", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded

    if MapSet.member?(expanded, id) do
      {:noreply, assign(socket, :expanded, MapSet.delete(expanded, id))}
    else
      viewer = socket.assigns.current_user
      lines = socket.assigns.quote_lines

      {:noreply,
       socket
       |> assign(:expanded, MapSet.put(expanded, id))
       |> update(:items, fn items ->
         Enum.map(items, &if(&1.id == id, do: with_reply_preview(&1, viewer, lines), else: &1))
       end)
       |> assign_sections()}
    end
  end

  # "Show N more" on a card: every line from then on, for this card.
  def handle_event("unfold", %{"id" => id}, socket) do
    {:noreply, update(socket, :unfolded, &MapSet.put(&1, id))}
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
      # Not part of what this chip shows: it belongs to neither the list nor
      # the chip's total.
      filtered_out?(item, socket.assigns.filter) ->
        {:noreply, socket}

      # An older page is a fixed window into the past: merging a brand-new
      # event into it would show it out of order and push everything below it
      # down by one. Only the total grows, so the event is on page 1 the next
      # time the reader loads it.
      socket.assigns.page > 1 ->
        {:noreply, update(socket, :total, &(&1 + 1))}

      true ->
        {[item], posts} = with_post_previews([item], socket.assigns.current_user)

        {:noreply,
         socket
         |> update(:items, fn items ->
           [item | Enum.reject(items, &(&1.id == item.id))] |> Enum.take(@page_size)
         end)
         # The page already holds a card for every post it shows, so only the
         # first event about a *new* post builds one here.
         |> update(:post_cards, &Map.merge(&1, post_cards([item], posts, &1)))
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
  # filter and the *requested* page, so a patch to another chip or page can
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

    {items, posts} =
      feed.entries
      |> with_seen_flags(user, socket.assigns.dismissed)
      |> with_post_previews(user)

    %{page: page, total: total, items: items, post_cards: post_cards(items, posts)}
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
    sections =
      socket.assigns.items
      |> Groups.sections(socket.assigns.read_marker)
      |> Enum.map(&Map.put(&1, :rows, with_seen_rule(&1.groups)))

    socket
    |> assign(:sections, sections)
    |> assign(:empty?, sections == [])
  end

  # `[{group, rule?}]`: the "Seen before" rule sits before the first seen card
  # that follows a new one in the same day — once, since `Groups` sorts a
  # day's new cards ahead of its seen ones. A day that is all new or all seen
  # draws no rule.
  defp with_seen_rule(groups) do
    {rows, _state} =
      Enum.map_reduce(groups, :before, fn group, state ->
        cond do
          group.unread? -> {{group, false}, :new_seen}
          state == :new_seen -> {{group, true}, :done}
          true -> {{group, false}, state}
        end
      end)

    rows
  end

  defp filtered_out?(item, filter) do
    case @filters[filter] do
      nil -> false
      kinds -> item.kind not in kinds
    end
  end

  # The day's first thread line, for the opt-out hint (issue #1025): one hint
  # per day, on the first line that would be silenced.
  defp first_thread_line_id(groups) do
    Enum.find_value(groups, fn
      %{kind: "post", events: events} -> Enum.find_value(events, &(&1.verb == :thread && &1.id))
      _group -> nil
    end)
  end

  # What is new since the last visit, per chip. The whole-feed count is what
  # the shell badge showed; the split into chips is one more query, and only
  # when there is something to split.
  defp unread_counts(user) do
    case Activity.unread_notification_count(user) do
      0 ->
        %{"all" => 0}

      all ->
        user
        |> Activity.unread_notification_counts(Map.delete(@filters, "all"))
        |> Map.put("all", all)
    end
  end

  # The rail and the summary line need the DB and the viewer's follow graph;
  # the static render skips both (they arrive with the connected mount).
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
    |> assign(:summary, if(summary_total(summary) > 0, do: summary, else: nil))
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
        <%!-- `data-filter-scope` pairs the chips with the list they replace: the
        in-flight paint in `app.css` dims every `[data-filter-list]` inside this
        container while one of its chips is waiting for an answer, so both
        markers have to stay under this one element. --%>
        <div data-filter-scope class="min-w-0 md:col-span-2">
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">
              {gettext("Notifications")}
            </h1>
            <p
              :if={unread_badge(@new_counts, "all")}
              id="new-count"
              class="mb-0 text-sm font-semibold text-accent"
            >
              {new_count_label(unread_badge(@new_counts, "all"))}
            </p>
          </div>

          <%!-- The last 30 days as one quiet line: the context the reader
          glances at, never the thing they came for. --%>
          <p
            :if={@summary}
            id="activity-summary"
            class="mb-0 mt-1 text-xs text-slate-600 dark:text-slate-400"
          >
            {summary_line(@summary)}
          </p>

          <%!-- `data-filter-bar="track"` picks which of the app's two tab looks
          the in-flight paint reaches for: here the white pill on a filled
          trough, so a pressed chip turns into this bar's own active chip rather
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
              {label}<span
                :if={unread_badge(@new_counts, value)}
                data-filter-count
                class="ml-1.5 inline-flex min-w-5 items-center justify-center rounded-full bg-accent px-1.5 text-[11px] font-bold leading-5 text-white"
              >{compact_count(unread_badge(@new_counts, value))}</span>
            </.link>
          </div>

          <%!-- Everything a chip replaces lives in one `data-filter-list`, so the
          shared paint can dim it while the answer is on its way. The chips stay
          outside it: the reader has to keep seeing which one they pressed. --%>
          <div data-filter-list>
            <section :for={section <- @sections} data-day-section>
              <h2
                class="mb-0 mt-6 text-sm font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400"
                data-day-heading
              >
                {day_label(section.day, @today)}
              </h2>
              <% thread_hint_id = first_thread_line_id(section.groups) %>
              <div class="mt-2 space-y-3">
                <%= for {group, rule?} <- section.rows do %>
                  <div
                    :if={rule?}
                    data-seen-rule
                    class="flex items-center gap-3 px-1 pt-1 text-xs font-semibold text-slate-500 dark:text-slate-400"
                  >
                    <span class="h-px flex-1 bg-slate-200 dark:bg-slate-700" aria-hidden="true"></span>
                    {gettext("Seen before")}
                    <span class="h-px flex-1 bg-slate-200 dark:bg-slate-700" aria-hidden="true"></span>
                  </div>
                  <.notification_card
                    group={group}
                    current_user={@current_user}
                    quote_lines={@quote_lines}
                    post_cards={@post_cards}
                    expanded={@expanded}
                    unfolded={@unfolded}
                    thread_hint_id={thread_hint_id}
                  />
                <% end %>
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
        </aside>
      </div>
    </div>
    """
  end

  # The page size, as a function: inside ~H a bare `@page_size` would read the
  # assigns, not the module attribute.
  defp page_size, do: @page_size

  # The pager carries the active chip onto every page link, so paging inside a
  # filter stays inside it.
  defp pager_query("all"), do: %{}
  defp pager_query(filter), do: %{"filter" => filter}

  # ── One card ──

  attr(:group, :map, required: true)
  attr(:current_user, :any, required: true)
  attr(:quote_lines, :integer, required: true)
  attr(:post_cards, :map, default: %{})
  attr(:expanded, :any, required: true)
  attr(:unfolded, :any, required: true)
  attr(:thread_hint_id, :string, default: nil)

  defp notification_card(%{group: %{kind: "post"}} = assigns) do
    lines = assigns.group.events
    unfolded? = MapSet.member?(assigns.unfolded, assigns.group.id)
    shown = if unfolded?, do: lines, else: Enum.take(lines, @card_lines)

    assigns =
      assigns
      |> assign(:card, Map.get(assigns.post_cards, assigns.group.post_id))
      |> assign(:shown, shown)
      |> assign(:hidden, length(lines) - length(shown))

    ~H"""
    <.notification_article group={@group}>
      <.post_card_head
        card={@card}
        eyebrow={card_eyebrow(@card, @group, @current_user)}
        counts={card_counts(@group.events)}
        at={@group.at}
        unread?={@group.unread?}
      />

      <ul class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
        <.card_line
          :for={line <- @shown}
          line={line}
          current_user={@current_user}
          quote_lines={@quote_lines}
          expanded={MapSet.member?(@expanded, line.id)}
          thread_hint={line.id == @thread_hint_id}
        />
      </ul>

      <button
        :if={@hidden > 0}
        type="button"
        phx-click="unfold"
        phx-value-id={@group.id}
        data-card-more
        class="mt-1 inline-flex min-h-10 items-center text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {gettext("Show %{formatted} more", formatted: compact_count(@hidden))}
      </button>
    </.notification_article>
    """
  end

  # The day's people: their avatars, a tally, and one line per verb.
  defp notification_card(%{group: %{kind: "people"}} = assigns) do
    ~H"""
    <.notification_article group={@group}>
      <div class="flex items-start gap-3">
        <div class="flex shrink-0 -space-x-2">
          <.avatar
            :for={actor <- Enum.take(@group.actors, 4)}
            src={actor.avatar}
            size="sm"
            presence
            presence_id={actor.id}
            alt={"Avatar of #{actor.name}"}
            class="ring-2 ring-white dark:ring-slate-900"
          />
        </div>
        <div class="min-w-0 flex-1">
          <span data-card-eyebrow class={eyebrow_class()}>{gettext("People")}</span>
          <span
            data-card-title
            class="mt-0.5 block text-sm font-medium text-slate-900 dark:text-white"
          >
            {people_title(@group)}
          </span>
        </div>
        <.row_meta at={@group.at} unread?={@group.unread?} />
      </div>

      <ul class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
        <.card_line
          :for={line <- @group.events}
          line={line}
          current_user={@current_user}
          quote_lines={@quote_lines}
          expanded={false}
          thread_hint={false}
        />
      </ul>
    </.notification_article>
    """
  end

  # Every rarer kind: one row per event, each carrying its own content.
  defp notification_card(assigns) do
    assigns = assign(assigns, :n, assigns.group.item)

    ~H"""
    <.notification_article group={@group} class="flex gap-3">
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
      <.row_meta at={@group.at} unread?={@group.unread?} />
    </.notification_article>
    """
  end

  # The shell every card wears, whatever it holds: the id and the markers the
  # tests and the CSS key on (`assets/css/components.css` reads
  # `[data-notification-row][data-unread]` to paint the quote clamp's fade on
  # the card's own tint, so the tint cannot live in only one of the clauses).
  attr(:group, :map, required: true)
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  defp notification_article(assigns) do
    ~H"""
    <article
      id={"notification-#{@group.id}"}
      data-notification-row
      data-kind={@group.kind}
      data-unread={@group.unread? && "true"}
      class={[
        "rounded-2xl bg-white px-4 py-3 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800 sm:px-5",
        @class,
        @group.unread? && "bg-brand-50/60 dark:bg-brand-900/15"
      ]}
    >
      {render_slot(@inner_block)}
    </article>
    """
  end

  # The right edge of a card head, a card line and a single row alike: the
  # clock time over the unread dot.
  attr(:at, :any, required: true)
  attr(:unread?, :boolean, required: true)

  defp row_meta(assigns) do
    ~H"""
    <div class="flex shrink-0 flex-col items-end gap-1.5 pt-0.5">
      <.row_time at={@at} />
      <.unread_dot :if={@unread?} />
    </div>
    """
  end

  attr(:class, :string, default: nil)

  defp unread_dot(assigns) do
    ~H"""
    <span class={["h-2 w-2 rounded-full bg-accent", @class]}>
      <span class="sr-only">{gettext("New")}</span>
    </span>
    """
  end

  defp eyebrow_class,
    do:
      "block text-[11px] font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400"

  # ── The head of a post card ──

  # What the post says on the left, its first photos or its link screenshot on
  # the right, and under the text a line counting what came back. Above it all
  # an eyebrow saying whose post this is — the reader's own for a like or a
  # reply, somebody else's for a mention, a thread they wrote in.
  #
  # The text starts at the same edge whether the post carries a picture or not
  # — the pictures hang off the right — so a column of cards reads as one
  # column rather than as two indents. The head is one link to the post: the
  # reader's question is "which post was that", and the answer is one tap away.
  attr(:card, :any, required: true)
  attr(:eyebrow, :string, required: true)
  attr(:counts, :list, required: true)
  attr(:at, :any, required: true)
  attr(:unread?, :boolean, required: true)

  defp post_card_head(assigns) do
    ~H"""
    <div class="flex items-start gap-3">
      <div class="min-w-0 flex-1">
        <span :if={@eyebrow} data-card-eyebrow class={eyebrow_class()}>{@eyebrow}</span>
        <.link
          :if={@card}
          href={Posts.path(@card.post)}
          data-post-card
          class="mt-0.5 block text-sm font-medium text-slate-900 hover:text-brand-700 dark:text-white dark:hover:text-brand-300"
        >
          <%!-- A photo post has no text to name it with (`PostTeaser` skips an
          image-only line), so the card says so rather than opening on a blank
          line the reader has to interpret. --%>
          <span
            :if={@card.text == ""}
            data-post-card-textless
            class="italic font-normal text-slate-500 dark:text-slate-400"
          >
            {gettext("Post without text")}
          </span>
          <span :if={@card.text != ""} class="line-clamp-2 whitespace-pre-line">{@card.text}</span>
        </.link>
        <%!-- The post is hidden from the reader or gone (a visibility-scoped
        lookup returned nothing): the lines below still say what happened. --%>
        <p :if={!@card} class="mb-0 mt-0.5 text-sm italic text-slate-500 dark:text-slate-400">
          {gettext("The post is no longer available.")}
        </p>
        <span :if={@counts != []} class="mt-0.5 block text-xs text-slate-500 dark:text-slate-400">
          {Enum.join(@counts, " · ")}
        </span>
      </div>

      <.post_card_images :if={@card} card={@card} big={@card.text == ""} />
      <.post_card_screenshot :if={@card && @card.images == [] && @card.screenshot} card={@card} />

      <.row_meta at={@at} unread?={@unread?} />
    </div>
    """
  end

  # Up to two photos, then the rest as a count on the second one. Two, because
  # the card's right edge has to sit in the same place whether the post carries
  # two pictures or twenty — a strip that grows with the picture count would
  # make the text column a different width on every card.
  #
  # On a post with no text the photo *is* what names it, so it takes the space
  # the missing text left and is rendered a size larger.
  attr(:card, :map, required: true)
  attr(:big, :boolean, default: false)

  defp post_card_images(assigns) do
    ~H"""
    <.link
      :if={@card.images != []}
      href={Posts.path(@card.post)}
      data-post-card-images
      class="flex shrink-0 gap-1"
    >
      <span :for={{image, index} <- Enum.with_index(@card.images)} class="relative block">
        <img
          src={PostImage.url(image, "thumb")}
          alt={PostComponents.photo_alt(image)}
          loading="lazy"
          class={["rounded-lg object-cover", if(@big, do: "h-16 w-16", else: "h-12 w-12")]}
        />
        <span
          :if={@card.more_images > 0 and index == length(@card.images) - 1}
          data-images-more={@card.more_images}
          class="absolute bottom-0.5 right-0.5 rounded-md bg-slate-900/70 px-1 text-[11px] font-semibold leading-tight text-white"
        >
          +{compact_count(@card.more_images)}
        </span>
      </span>
    </.link>
    """
  end

  # A link post's auto screenshot, in the slot the photos would take: the same
  # capture the feed floats beside the post, at thumbnail size, so a card about
  # a shared link shows the page it points at. Decorative — the head's text link
  # already names and opens the post — so it is kept out of the tab order.
  attr(:card, :map, required: true)

  defp post_card_screenshot(assigns) do
    ~H"""
    <.link
      href={Posts.path(@card.post)}
      data-post-card-screenshot
      aria-hidden="true"
      tabindex="-1"
      class="shrink-0"
    >
      <.picture
        picture={Screenshot.picture({@card.screenshot.screenshot, @card.screenshot})}
        width="72"
        height="48"
        loading="lazy"
        alt=""
        class="h-12 w-[4.5rem] rounded-lg object-cover ring-1 ring-slate-200 dark:ring-slate-800"
      />
    </.link>
    """
  end

  # ── One line inside a card ──

  # Who did what, on one line: a small kind glyph, the actors, the verb — and
  # for a reply its words, clamped to two lines, as the button that unfolds
  # the formatted quote. The card's head already named the post, so no line
  # repeats it.
  attr(:line, :map, required: true)
  attr(:current_user, :any, required: true)
  attr(:quote_lines, :integer, required: true)
  attr(:expanded, :boolean, required: true)
  attr(:thread_hint, :boolean, default: false)

  defp card_line(assigns) do
    assigns =
      assigns
      |> assign(:n, assigns.line.item)
      |> assign(:teaser, line_teaser(assigns.line))
      |> assign(:kind, line_kind(assigns.line))

    ~H"""
    <li
      id={"notification-#{@line.id}"}
      data-notification-event
      data-event-kind={@kind}
      data-unread={@line.unread? && "true"}
      class="py-2 first:pt-0 last:pb-0"
    >
      <div class="flex items-start gap-2.5">
        <span
          class={[
            "mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-bold",
            kind_classes(@kind)
          ]}
          aria-hidden="true"
        >
          {kind_glyph(@kind)}
        </span>
        <div class="min-w-0 flex-1">
          <p class="mb-0 text-sm leading-relaxed text-slate-800 dark:text-slate-100">
            <span class="sr-only">{kind_label(@kind)}:</span>
            <.actor_links group={@line} current_user={@current_user} named={named_actors(@line)} />
            {line_text(@line)}
          </p>

          <%!-- Folded: the reply's words, two lines of them, as the button that
          opens the rest. A private reply from another network (issue #1071)
          says so right here, since the member has to know that before they
          answer, not after they unfold it. --%>
          <button
            :if={@teaser && !@expanded}
            type="button"
            phx-click="toggle_line"
            phx-value-id={@line.id}
            data-line-toggle
            aria-expanded="false"
            class="mt-0.5 block w-full text-left text-sm text-slate-600 hover:text-slate-900 dark:text-slate-400 dark:hover:text-slate-200"
          >
            <span :if={remote_private?(@n)} data-remote-private aria-hidden="true">🔒</span>
            <span data-reply-teaser class="line-clamp-2 whitespace-pre-line">{@teaser}</span>
          </button>

          <%!-- Unfolded: the quote formatted like a feed post (or the remote
          reply's plain text), the Reply link to where an answer is written,
          and the way back. --%>
          <div :if={@expanded} class="mt-1.5 space-y-1.5">
            <.quoted_post
              :if={local_reply?(@line) and @n[:reply_preview]}
              id={"quote-#{@line.id}"}
              data-reply-preview="true"
              href={Posts.path(@n.reply_preview.post)}
              html={@n.reply_preview.html}
              quote_lines={@quote_lines}
            />
            <.remote_reply
              :if={@line.verb == :remote_reply and @n[:note_text]}
              id={"quote-remote-#{@line.id}"}
              n={@n}
              current_user={@current_user}
              quote_lines={@quote_lines}
            />
            <div class="flex flex-wrap items-center gap-x-4">
              <.link
                href={reply_target(@line, @current_user)}
                data-reply-link
                class="inline-flex min-h-10 items-center text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
              >
                {gettext("Reply")} ›
              </.link>
              <button
                type="button"
                phx-click="toggle_line"
                phx-value-id={@line.id}
                data-line-toggle
                aria-expanded="true"
                class="inline-flex min-h-10 items-center text-sm font-medium text-slate-600 hover:text-slate-900 dark:text-slate-400 dark:hover:text-slate-200"
              >
                {gettext("Less")}
              </button>
            </div>
          </div>

          <%!-- The day's first thread line says why it is here and links to the
          switch that stops it (issue #1025), once per day so it stays a hint and
          not a banner. It shows only when thread events reach this reader, which
          is exactly when the switch is still on. --%>
          <p
            :if={@thread_hint}
            data-thread-hint
            class="mb-0 mt-1 text-xs text-slate-500 dark:text-slate-400"
          >
            {gettext("You wrote in this thread.")}
            <.link
              href={~p"/settings/notifications"}
              class="font-medium text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
            >
              {gettext("Turn off thread notifications")} ›
            </.link>
          </p>
        </div>
        <.row_meta at={@line.at} unread?={@line.unread?} />
      </div>
    </li>
    """
  end

  # The post a line quotes, formatted exactly the way /feed formats a post: the
  # rendered Markdown in the `.markdown markdown--post` body recipe (headings
  # flattened to bold, @mentions and #hashtags linked), clipped by `.notif-clamp`
  # to the reader's line budget.
  #
  # It is a block with a *stretched* permalink link rather than one big `<a>`,
  # because a formatted body carries links of its own and an `<a>` inside an
  # `<a>` is invalid: the prose falls through to the stretched link, so a click
  # anywhere still opens the post, while a mention/hashtag/URL keeps its own
  # target. The feed's "Suggested posts" rail is arranged the same way.
  # `id` is what lets the clamp measurement re-run after a patch: the block is
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

  # A reply written on another network (issue #1069). Plain text, clamped like
  # the other quotes and deliberately NOT run through the Markdown renderer: a
  # stranger's words must not be able to mint links, least of all @mention links
  # into local profiles. A private reply (issue #1071) says so, since the member
  # has to know that before they answer.
  #
  # The same solid quote rail the local reply quotes wear — the line above it
  # already says it came from another network, so the quote needs no dashed
  # variant of its own. Marked for the clamp measurement like those quotes too,
  # so a remote reply that runs past the reader's line budget also ends in a "…".
  #
  # And it is a link, on the same stretched-overlay arrangement as
  # <.quoted_post>: a readable block of somebody's words is what the reader
  # reaches for, so a quote that does nothing on tap reads as a broken line,
  # whichever network the words came from. It goes where the line's own sentence
  # already goes (the reader's post, not the stranger's server, which the card
  # over there links to) and carries the note's anchor, so a post that collected
  # several replies opens on this one. No `[&_a]:relative` escape hatch is needed
  # inside: unlike a local quote's Markdown, this text is deliberately never
  # linkified, so there is no inner link for the overlay to swallow.
  attr(:id, :string, required: true)
  attr(:n, :map, required: true)
  attr(:current_user, :any, required: true)
  attr(:quote_lines, :integer, required: true)

  defp remote_reply(assigns) do
    ~H"""
    <div class="space-y-1">
      <p
        :if={remote_private?(@n)}
        data-remote-private
        class="mb-0 text-xs font-medium text-slate-600 dark:text-slate-400"
      >
        <span aria-hidden="true">🔒</span> {gettext("Sent to you only, visible to nobody else")}
      </p>
      <div
        id={@id}
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
        <%!-- No `text-*` / `leading-*` here: `.notif-clamp` owns the type size
        and line height, since its box height is counted in them. --%>
        <p
          data-clamp-body
          class="notif-clamp mb-0 whitespace-pre-line text-slate-600 dark:text-slate-400"
          {clamp_attrs(@quote_lines)}
        >{@n.note_text}</p>
      </div>
    </div>
    """
  end

  defp remote_private?(n), do: is_binary(n[:note_audience]) and n.note_audience != "public"

  # The row's left visual (the single rows): the lead (newest) actor's avatar
  # with a small kind badge riding its corner - or, for a picture-less lead
  # actor and the actor-less kinds (moderation, image review), the colored kind
  # glyph circle. Either way a present actor gets the online-presence dot via
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

  # The sentence's subject: up to `named` linked actor names, the rest folded
  # into "and N more" - which links to the recipient's own followers /
  # connections list where that is the natural place to see everyone.
  attr(:group, :map, required: true)
  attr(:current_user, :any, required: true)
  attr(:named, :integer, default: nil, doc: "nil: the page's default from Groups")

  defp actor_links(assigns) do
    named = Enum.take(assigns.group.actors, assigns.named || Groups.named_actors())
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

  # One actor's name, linked. Three shapes: a member or a page
  # (`actor_path/1`, never `~p"/#{@actor.param}"` — a page's param is a slug
  # under /organizations/:slug, and the root belongs to member handles, issue
  # #1336); somebody on another network (issue #1069) — no vutuv profile behind
  # the name, so a press opens the account card over it, the same card their
  # handle opens on a post card (`remote_actor_link/3`), with the `@handle@host`
  # beside the name saying which network answered and the `href` out there
  # still what a middle click takes; and a bare name for a payload with neither.
  #
  # Deliberately ONE line of markup: the pieces sit inside a sentence, and any
  # newline between them is whitespace the browser renders — which is how the
  # old `cond` put a space before every comma ("Anna , Ben und 3 weitere").
  attr(:actor, :map, required: true)

  defp actor_link(assigns) do
    assigns =
      assigns
      |> assign(:remote?, is_nil(assigns.actor.param) and is_binary(assigns.actor[:url]))
      |> assign(:bare?, is_nil(assigns.actor.param) and not is_binary(assigns.actor[:url]))

    ~H"""
    <.link :if={@actor.param} href={actor_path(@actor)} class={actor_name_class()}>{@actor.name}</.link><.link :if={@remote?} {remote_actor_link(nil, @actor.url, @actor[:handle])} class={actor_name_class()}>{@actor.name}</.link><span :if={@remote? and @actor[:handle] && @actor.handle != @actor.name} class="text-xs font-normal text-slate-600 dark:text-slate-400"> {@actor.handle}</span><span :if={@bare?} class="font-semibold">{@actor.name}</span>
    """
  end

  defp actor_name_class,
    do:
      "font-semibold text-slate-900 hover:text-brand-700 dark:text-white dark:hover:text-brand-300"

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
  # people kinds; nowhere for a like line (there is no public likers list).
  defp overflow_href("follower", viewer), do: ~p"/#{viewer}/followers"
  defp overflow_href("connection", viewer), do: ~p"/#{viewer}/connections"
  defp overflow_href(_kind, _viewer), do: nil

  # ── Header bits ──

  defp filter_options do
    [
      {"all", gettext("All")},
      {"replies", gettext("Replies")},
      {"reactions", gettext("Reactions")},
      {"people", gettext("People")},
      {"other", gettext("More")}
    ]
  end

  defp filter_path("all"), do: ~p"/notifications"
  defp filter_path(value), do: ~p"/notifications?filter=#{value}"

  # The active chip reads as a raised white pill, the rest as quiet muted text
  # - the segmented-control treatment of the post-type filter tabs.
  defp filter_tab_class(true),
    do:
      "inline-flex min-h-9 items-center whitespace-nowrap rounded-md bg-white px-3 py-1 font-semibold text-brand-700 shadow-sm dark:bg-slate-900 dark:text-brand-100"

  defp filter_tab_class(false),
    do:
      "inline-flex min-h-9 items-center whitespace-nowrap rounded-md px-3 py-1 font-medium text-slate-600 hover:text-slate-900 dark:text-slate-400 dark:hover:text-slate-100"

  # A chip's badge: the count of what is new under it, nothing at zero.
  defp unread_badge(counts, filter) do
    case Map.get(counts, filter) do
      count when is_integer(count) and count > 0 -> count
      _ -> nil
    end
  end

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

  # The line's clock time: sections are the reader's calendar days, so the
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

  # ── The 30-day summary line ──

  # "Last 30 days: 163 likes · 68 replies · 47 followers …", zero parts
  # dropped. Every part is its own complete translatable phrase — the line is a
  # list of facts, not a sentence assembled from pieces.
  defp summary_line(summary) do
    parts =
      [
        likes_label(summary.likes),
        replies_label(summary.replies),
        count_label(
          summary.followers,
          &ngettext("%{formatted} follower", "%{formatted} followers", &1, &2)
        ),
        count_label(
          summary.connections,
          &ngettext("%{formatted} connection", "%{formatted} connections", &1, &2)
        ),
        endorsements_label(summary.endorsements)
      ]
      |> Enum.reject(&is_nil/1)

    gettext("Last 30 days: %{parts}", parts: Enum.join(parts, " · "))
  end

  # ── Kind styling (badge colour + glyph + accessible label) ──

  # Event kinds that share the brand badge colour, so the class string lives
  # in one place.
  @brand_kind_classes "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"
  @brand_kinds ~w(follower reply thread mention connection report_protection organization_role handle_change cv_update fediverse_reply fediverse_reaction share)

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
  # Being named by @handle. Shares the glyph with the (rare, "More"-chip)
  # handle-change kind: both are about a handle, and the badge's title/sr-only
  # label tells them apart where the glyph alone would not.
  defp kind_glyph("mention"), do: "@"
  defp kind_glyph("like"), do: "♥"
  # A re-share from another network (issue #1068): the arrows, since the line
  # beside it names the verb and the globe already sits on the sharer's name.
  defp kind_glyph("share"), do: "↻"
  # A reply written on another network (issue #1069) — the same globe the
  # post card's "from other networks" line uses, so one glyph means one thing.
  defp kind_glyph("fediverse_reply"), do: "🌐"
  # A reaction from out there of a kind that is neither a favourite nor a
  # re-share — the globe, since "this came from another network" is the one
  # thing the glyph has to say; the sentence beside it names the verb.
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
  defp kind_label("share"), do: gettext("Reaction from another network")
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

  # ── A card line's vocabulary ──

  # The verbs whose kind string is the verb's own name.
  @named_verbs [:reply, :thread, :mention, :follower, :connection, :endorsement]

  # The two verbs that quote a member's post: a folded line carries its
  # teaser, an unfolded one the formatted quote. A mention is deliberately not
  # one of them — the card's head already IS the naming post — and a remote
  # reply quotes a note rather than a post.
  @local_reply_verbs [:reply, :thread]

  # The one kind string a card line wears — for its glyph, colour and label
  # AND for its `data-event-kind`, so what the line looks like and what a test
  # or a stylesheet keys on can never say two different things. The verb
  # decides, not the newest item's kind: a merged like line may have a
  # favourite from another network as its newest member and is still "like".
  defp line_kind(%{verb: :like}), do: "like"
  defp line_kind(%{verb: :share}), do: "share"
  defp line_kind(%{verb: :reaction}), do: "fediverse_reaction"
  defp line_kind(%{verb: :remote_reply}), do: "fediverse_reply"
  defp line_kind(%{verb: verb}) when verb in @named_verbs, do: Atom.to_string(verb)
  defp line_kind(%{kind: kind}), do: kind

  defp local_reply?(%{verb: verb}), do: verb in @local_reply_verbs

  # A like or re-share line names three before folding; the people lines and
  # the single rows keep the page's default of two.
  defp named_actors(%{verb: verb}) when verb in [:like, :share, :reaction], do: 3
  defp named_actors(_line), do: Groups.named_actors()

  # The sentence after the actor names. The card's head already named the post,
  # so a line says only what was done. German conjugates the verb across the
  # count where English conjugates it the other way round ("likes this" is the
  # singular), so those are count-branched msgids rather than one string with a
  # number in it.
  defp line_text(%{verb: :like, actor_count: count}),
    do: ngettext("likes this.", "like this.", count)

  defp line_text(%{verb: :share, actor_count: count}),
    do: ngettext("shared this.", "shared this.", count)

  defp line_text(%{verb: :reaction, actor_count: count}),
    do: ngettext("reacted to this.", "reacted to this.", count)

  defp line_text(%{verb: verb}) when verb in [:reply, :remote_reply], do: gettext("replied.")
  defp line_text(%{verb: :thread}), do: gettext("replied in the thread.")
  defp line_text(%{verb: :mention}), do: gettext("mentioned you.")
  defp line_text(line), do: group_text(line)

  # The reply's words on the folded line: the local reply's teaser, or the
  # remote note's text folded to one line. Nothing for a like, a share or a
  # reply the reader may not see.
  defp line_teaser(%{verb: verb, item: item}) when verb in @local_reply_verbs,
    do: item[:reply_teaser]

  defp line_teaser(%{verb: :remote_reply, item: item}), do: item[:note_teaser]
  defp line_teaser(_line), do: nil

  # Where a line's Reply link leads: the reply itself, so the answer is written
  # under the words it answers; a remote reply to the conversation anchored at
  # that note; anything else to what the notification itself opens.
  defp reply_target(%{verb: verb, item: %{reply_preview: %{post: post}}}, _viewer)
       when verb in @local_reply_verbs,
       do: Posts.path(post)

  defp reply_target(%{verb: :remote_reply, item: item}, viewer),
    do: remote_reply_target(item, viewer)

  defp reply_target(%{item: item}, viewer), do: notification_target(item, viewer)

  # The grouped sentence tail after the actor names, for the people lines and
  # the single rows. Only the forms that differ from the single-actor one are
  # spelled here - German conjugates the follower/connection verbs across the
  # count where English does not, hence the count-branched msgids. Everything
  # else falls through to VutuvWeb.NotificationLine, which the browser
  # notification shares, so one event cannot read differently in the two places
  # (issue #1249).
  defp group_text(%{kind: "follower", actor_count: count}) when count > 1,
    do: gettext("are now following you.")

  defp group_text(%{kind: "connection", actor_count: count}) when count > 1,
    do: gettext("are now connected with you.")

  defp group_text(%{kind: "endorsement", tags: [tag]}),
    do: notification_text(%{kind: "endorsement", tag: tag})

  defp group_text(%{kind: "endorsement", tags: [_ | _] = tags}),
    do: gettext("endorsed you for %{tags}.", tags: join_names(tags))

  defp group_text(%{item: item}), do: notification_text(item)

  # ── The card heads ──

  # Whose post a card is about. The reader's own for a like, a reply, a thread
  # they rooted; somebody else's for a mention or a thread they wrote in — the
  # thread wording says why a stranger's post is on the reader's page at all.
  # Nothing when the post itself is out of reach: the head says so in words.
  defp card_eyebrow(nil, _group, _viewer), do: nil

  defp card_eyebrow(%{post: post}, group, viewer) do
    cond do
      Posts.self_vote?(post, viewer) ->
        gettext("Your post")

      Enum.any?(group.events, &(&1.verb == :thread)) ->
        gettext("Thread by %{name}", name: PostTeaser.author_of(post).name)

      true ->
        gettext("Post by %{name}", name: PostTeaser.author_of(post).name)
    end
  end

  # What the card's head counts: likes and re-shares by distinct actor, and
  # every line that carries words — a reply, a thread answer, a mention, one
  # from another network. Each fragment is its own complete translatable
  # phrase — the line is a list of facts, not a sentence assembled from pieces.
  defp card_counts(events) do
    likes = actor_sum(events, :like)
    shares = actor_sum(events, :share)
    replies = Enum.count(events, &Groups.reply_verb?/1)

    [likes_label(likes), shares_label(shares), replies_label(replies)]
    |> Enum.reject(&is_nil/1)
  end

  defp actor_sum(events, verb) do
    events
    |> Enum.filter(&(&1.verb == verb))
    |> Enum.map(& &1.actor_count)
    |> Enum.sum()
  end

  # The people card's title: the day's tally, each part its own phrase.
  defp people_title(%{events: events}) do
    [
      count_label(
        actor_sum(events, :connection),
        &ngettext("%{formatted} new connection", "%{formatted} new connections", &1, &2)
      ),
      count_label(
        actor_sum(events, :follower),
        &ngettext("%{formatted} new follower", "%{formatted} new followers", &1, &2)
      ),
      endorsements_label(Enum.count(events, &(&1.verb == :endorsement)))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # `ngettext/3` binds `%{count}` to the raw integer and a `count:` binding does
  # not override it, so the formatted number rides a placeholder of its own.
  defp count_label(0, _phrase), do: nil
  defp count_label(count, phrase), do: phrase.(count, formatted: compact_count(count))

  # One phrase per noun, shared by the card head's counts, the people tally
  # and the 30-day line, so the same fact is never worded twice.
  defp likes_label(n),
    do: count_label(n, &ngettext("%{formatted} like", "%{formatted} likes", &1, &2))

  defp shares_label(n),
    do: count_label(n, &ngettext("%{formatted} share", "%{formatted} shares", &1, &2))

  defp replies_label(n),
    do: count_label(n, &ngettext("%{formatted} reply", "%{formatted} replies", &1, &2))

  defp endorsements_label(n),
    do: count_label(n, &ngettext("%{formatted} endorsement", "%{formatted} endorsements", &1, &2))

  # "Elixir, Phoenix and Rails" - all but the last joined by commas, the last
  # by the localized joining word.
  defp join_names([single]), do: single

  defp join_names(names) do
    {front, [last]} = Enum.split(names, -1)
    Enum.join(front, ", ") <> " " <> gettext("and") <> " " <> last
  end

  # Where the quoted remote reply itself goes: the same conversation the line's
  # sentence opens, plus the anchor of this note (`Fediverse.reply_anchor/1`),
  # so a post that collected several replies lands on the one being quoted
  # rather than at the top. The anchor is dropped when the line somehow carries
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

  # Reply and thread notifications carry the reply's post id (`:reply_post_id`);
  # every post-bound kind carries the post the card is about (`:post_id`, or a
  # thread's `:root_post_id`); a handle change lists rewritten posts. Look every
  # referenced post up in one batched, visibility-scoped query and attach what
  # the folded lines show: the reply's one-line teaser (`:reply_teaser`) and a
  # remote note's text teased the same way (`:note_teaser`). The formatted
  # quote waits for the unfold (`with_reply_preview/3`). A post the viewer may
  # not see is absent from `posts`, so such an entry passes through unchanged
  # and its line shows the sentence alone.
  # Returns `{entries, posts}` — the looked-up posts come back out so the post
  # cards can be built from the same batch instead of asking for them again.
  defp with_post_previews(entries, viewer) do
    posts =
      entries
      |> Enum.flat_map(
        &[&1[:post_id], &1[:reply_post_id], &1[:root_post_id] | List.wrap(&1[:post_ids])]
      )
      |> then(&Posts.visible_posts_by_ids(viewer, &1))

    lines = User.notification_post_lines(viewer)

    entries =
      Enum.map(entries, fn entry ->
        entry
        |> put_teaser(posts)
        |> put_change_previews(posts, lines)
      end)

    {entries, posts}
  end

  # The formatted quote a line shows once unfolded (`toggle_line`), rendered
  # then and not before: one full Markdown pass, for the one reply somebody
  # opened. A line that already carries its quote keeps it.
  defp with_reply_preview(%{reply_preview: %{}} = item, _viewer, _lines), do: item

  defp with_reply_preview(%{reply_post_id: id} = item, viewer, lines) when is_binary(id),
    do:
      put_preview(
        item,
        :reply_preview,
        id,
        Posts.visible_posts_by_ids(viewer, [id]),
        lines,
        :html
      )

  defp with_reply_preview(item, _viewer, _lines), do: item

  # ── The head of a post card ──

  # How many of a post's photos ride its card before the rest become a count.
  # Two, so the card says "there are pictures, and here are the first of them"
  # without letting its right edge move with the picture count.
  @card_images 2

  # The card head clamps its teaser to two lines, so it asks `char_budget/1`
  # for two lines' worth of characters rather than keeping a second constant.
  @card_teaser_lines 2

  # The card heads for one page, as `%{post_id => card}`: the post itself, its
  # two-line teaser, its released photos and — for a link post with no photos
  # — its ready link screenshot.
  #
  # One entry per *post*, not per event — a post that collected a favourite, a
  # re-share and a reply is one card, and hanging that card off each raw item
  # instead would copy it as many times as there were reactions. That is not
  # free even though the copies share a reference in the process: the page
  # payload crosses `MountHandoff`'s ETS table, and ETS does not preserve
  # sharing (measured: 30 entries sharing one card cost 15 KB in-process and
  # 437 KB after an ETS round trip).
  #
  # `known` are the cards the page already holds, so a live push only looks up
  # a post that is not on the page yet.
  #
  # The teaser is `PostTeaser`, the app's shared one line, so the card skips a
  # quote post's `RE: <url>` opener and an image-only line exactly as the feed's
  # ticker does — which is also what leaves a photo post's head text-less, the
  # case `post_card_head/1` names in words.
  defp post_cards(entries, posts, known \\ %{}) do
    # Only ids the viewer may actually see reach the image query: `posts` is
    # already visibility-scoped, so a hidden or deleted post costs nothing here.
    ids =
      for entry <- entries,
          id = Groups.post_id_of(entry),
          is_map_key(posts, id),
          not is_map_key(known, id),
          uniq: true,
          do: id

    images = Posts.released_images_by_ids(ids)

    # Only a post with no photos shows its link screenshot, so only those ask.
    screenshots =
      ids
      |> Enum.filter(&(Map.get(images, &1, []) == []))
      |> Screenshots.ready_by_post_ids()

    for id <- ids, into: %{} do
      post = Map.fetch!(posts, id)
      photos = Map.get(images, id, [])

      {id,
       %{
         post: post,
         text: PostTeaser.plain_line(post, length: char_budget(@card_teaser_lines)),
         images: Enum.take(photos, @card_images),
         more_images: max(length(photos) - @card_images, 0),
         screenshot: if(photos == [], do: Map.get(screenshots, id))
       }}
    end
  end

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
    case quoted_excerpt(post, lines, :text) do
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
         %{} = excerpt <- quoted_excerpt(post, lines, form) do
      Map.put(entry, key, Map.put(excerpt, :post, post))
    else
      _ -> entry
    end
  end

  # The folded line's words, through the app's one teaser rule for both: a
  # member's reply as the post it is, a remote note as the `%Note{}` its text
  # came from (`Vutuv.RemoteHtml.to_text/3` reduced it to plain text at the
  # inbox, and `PostTeaser` knows not to run that through Markdown).
  defp put_teaser(%{kind: kind, reply_post_id: id} = entry, posts)
       when kind in ~w(reply thread) and is_binary(id) do
    case Map.get(posts, id) do
      %Post{} = post ->
        Map.put(entry, :reply_teaser, blank_to_nil(PostTeaser.plain_line(post)))

      _ ->
        entry
    end
  end

  defp put_teaser(%{kind: "fediverse_reply", note_text: text} = entry, _posts)
       when is_binary(text),
       do:
         Map.put(
           entry,
           :note_teaser,
           blank_to_nil(PostTeaser.plain_line(%Note{content_text: text}))
         )

  defp put_teaser(entry, _posts), do: entry

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  # The one-line form is the app's shared post teaser, so this page skips a
  # quote post's `RE: <url>` opener and an image-only first line exactly as the
  # feed's ticker and the RSS description do; the reader's line budget only
  # decides how many characters may ride the row. The formatted multi-line
  # quote is this page's own, and stays here.
  defp quoted_excerpt(post, lines, :text) do
    case PostTeaser.plain_line(post, length: char_budget(lines)) do
      "" -> nil
      text -> %{text: text}
    end
  end

  defp quoted_excerpt(post, lines, :html), do: preview_excerpt(post.body, lines)

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

  # The excerpt an unfolded reply line shows: the post's first `lines`
  # non-empty lines (the reader's `:notification_post_lines` preference), cut
  # server-side (not only by the CSS clamp) so the rest of a quoted body never
  # reaches the DOM. Returns nil for a body with no text left to show.
  defp preview_excerpt(body, lines) do
    source =
      @inline_image
      |> Regex.replace(body, "")
      |> String.split("\n")
      |> take_source_lines(lines)

    case String.trim(source) do
      "" -> nil
      trimmed -> render_excerpt(trimmed, lines)
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

  # The formatted rendering /feed gives a post, block-cut at the character
  # budget so one essay-long line still ships a small DOM. Images are
  # deliberately not passed: a quote is text.
  defp render_excerpt(source, lines) do
    {html, _truncated?} = Markdown.render_preview(source, [], limit: char_budget(lines))
    %{html: html}
  end

  defp char_budget(lines), do: lines * @preview_chars_per_line

  # The reader's line budget as an inline CSS custom property for `.notif-clamp`
  # — splatted, so a reader on the shipped default (what the stylesheet's own
  # fallback says) adds no attribute at all and the DOM stays clean.
  defp clamp_attrs(lines) do
    if lines == User.notification_post_lines_default(),
      do: [],
      else: [style: "--notif-clamp:#{lines}"]
  end
end
