defmodule VutuvWeb.TagLive.Timeline do
  @moduledoc """
  Everything written about a tag, on the tag page: vutuv posts and posts cached
  from other networks in one list the reader sorts, narrows and searches without
  a reload.

  Embedded by `VutuvWeb.TagController.show/2` via `live_render` (the profile's
  and the post permalink's pattern): the controller keeps owning the URL, the
  agent-format siblings and the page's front matter — description, most-endorsed
  members, open positions — and the socket owns the timeline below them.

  Mounted off-router, so it applies the session locale and resolves the viewer
  from the cookie's `session_token` itself
  (`VutuvWeb.Live.InitAssigns.assign_embedded/2`), never from a curated
  `user_id`.

  The query and every rule about what may be shown live in `Vutuv.Tags.Timeline`.
  "Most liked" ranks both kinds by a real tally since issue #1283 — a remote
  post by the figure its own origin publishes — so the apologetic note this page
  used to carry under that control is gone with the reason for it.

  Being off-router it cannot `push_patch`, so the controls do not rewrite the
  address bar. They are still readable **from** it: the controller passes the
  `?source=`, `?sort=`, `?q=`, `?from=` and `?until=` params into the mount
  session, so a link somebody sends opens on exactly that view.
  """

  use Phoenix.LiveView

  import VutuvWeb.PostComponents,
    only: [
      feed_filter_options: 0,
      post_filter_tabs: 1,
      post_list: 1,
      post_row_class: 0,
      post_thread_entry: 1,
      remote_post_card: 1
    ]

  import VutuvWeb.UI, only: [compact_count: 1, input_class: 0, load_more: 1]

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Fediverse
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.Timeline
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.Live.RemotePostActions

  # The origin's like/repost figures on a card from another network tick
  # while this page is open (issue #1283). One line, no handler.
  on_mount(VutuvWeb.Live.RemoteCounts)

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)

    case Repo.get(Tag, session["tag_id"]) do
      %Tag{} = tag ->
        {:ok,
         socket
         |> assign(:tag, tag)
         |> assign(:source, Timeline.normalize_source(session["source"]))
         |> assign(:sort, Timeline.normalize_sort(session["sort"]))
         |> assign(:query, Timeline.normalize_query(session["q"]))
         |> assign(:from, Timeline.normalize_date(session["from"]))
         |> assign(:until, Timeline.normalize_date(session["until"]))
         |> assign(:page, 1)
         |> load(reset: true)}

      _ ->
        # The controller resolved the tag a moment ago, so this is a deleted tag
        # racing a page load. Nothing to show and nothing to say about it.
        {:ok, socket |> assign(:tag, nil) |> assign(:entries, [])}
    end
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("filter-source", %{"type" => type}, socket) do
    {:noreply, socket |> assign(:source, Timeline.normalize_source(type)) |> reload()}
  end

  # One form for search, sort and the two dates, so every control is the same
  # round trip and a reader who types and then picks a sort never loses either.
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:query, Timeline.normalize_query(params["q"]))
     |> assign(:sort, Timeline.normalize_sort(params["sort"]))
     |> assign(:from, Timeline.normalize_date(params["from"]))
     |> assign(:until, Timeline.normalize_date(params["until"]))
     |> reload()}
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:query, nil)
     |> assign(:sort, :newest)
     |> assign(:from, nil)
     |> assign(:until, nil)
     |> reload()}
  end

  def handle_event("load-more", _params, socket) do
    {:noreply, socket |> update(:page, &(&1 + 1)) |> load(reset: false)}
  end

  # A report deletes our copy for everybody here, so the row leaves in the same
  # round trip rather than sitting there until the next load.
  def handle_event("report-remote-post", %{"id" => id}, socket) do
    RemotePostActions.report(socket, id, &drop_remote_entry(&1, id))
  end

  # ── Loading ───────────────────────────────────────────────────────────────

  defp reload(socket), do: socket |> assign(:page, 1) |> load(reset: true)

  defp load(socket, opts) do
    reset? = Keyword.fetch!(opts, :reset)

    page =
      Timeline.page(socket.assigns.tag,
        source: socket.assigns.source,
        sort: socket.assigns.sort,
        query: socket.assigns.query,
        from: socket.assigns.from,
        until: socket.assigns.until,
        page: socket.assigns.page
      )

    fresh = decorate(page.entries, socket.assigns.current_user)
    entries = if reset?, do: fresh, else: socket.assigns.entries ++ fresh

    socket
    # The stream is what renders; this list is what the row-level updates below
    # read (a stream cannot be enumerated), the arrangement the feed uses.
    |> assign(:entries, entries)
    |> assign(:total, page.total)
    |> assign(:more?, page.more?)
    # A stream has no count and no empty state of its own, so the flag rides
    # beside it.
    |> assign(:empty?, entries == [])
    |> stream(:entries, fresh, reset: reset?)
  end

  # What each card needs beyond the record itself, batched for the page rather
  # than read per row: the vutuv posts' counters and the reader's own state on
  # the remote ones.
  defp decorate(entries, viewer) do
    engagement = Posts.post_engagement_map(for(%{post: post} <- entries, do: post.id), viewer)
    remote = for %{remote_post: post} <- entries, do: post
    images = Fediverse.list_remote_images(Enum.map(remote, & &1.id))
    # Three reads for the whole page, handed to the bars. Without them each bar
    # loads its own three (`VutuvWeb.PostLive.RemoteActionsComponent`), which is
    # what this page did while it batched the reader's likes into a `:liked?`
    # the card has not taken since the bar became a component (issues #1275,
    # #1276) — a decoration nothing read, beside a lookup per card.
    marks = Fediverse.mark_lookup(remote, viewer)

    Enum.map(entries, fn
      %{post: post} = entry ->
        Map.put(entry, :engagement, Map.get(engagement, post.id))

      %{remote_post: post} = entry ->
        entry
        |> Map.put(:images, Map.get(images, post.id, []))
        |> Map.put(:marks, marks.(post))
    end)
  end

  defp drop_remote_entry(socket, remote_post_id) do
    case find_remote_entry(socket, remote_post_id) do
      %{id: id} = entry ->
        socket
        |> update(:entries, &Enum.reject(&1, fn entry -> entry.id == id end))
        |> update(:total, &max(&1 - 1, 0))
        |> stream_delete(:entries, entry)

      _ ->
        socket
    end
  end

  defp find_remote_entry(socket, remote_post_id) do
    Enum.find(
      socket.assigns.entries,
      &(Posts.remote_feed_entry?(&1) and &1.remote_post.id == remote_post_id)
    )
  end

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(%{tag: nil} = assigns) do
    ~H"""
    <div id="tag-timeline"></div>
    """
  end

  def render(assigns) do
    ~H"""
    <%!-- `data-filter-scope`: the source tabs and the timeline they govern in
    one container, so a press dims the list it is about while the answer is on
    its way (the rule lives in `assets/css/app.css`). --%>
    <section id="tag-timeline" data-filter-scope class="mt-6">
      <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
          {gettext("Posts with this tag")}
        </h2>
        <p data-timeline-total class="text-sm text-slate-600 dark:text-slate-400">
          {ngettext("%{formatted} post", "%{formatted} posts", @total, formatted: compact_count(@total))}
        </p>
      </div>

      <%!-- Tabs and the filter toggle share one row: they are the two controls
      that narrow this list, and stacking them put a lone blue line of its own
      under the tabs, reading as a third thing rather than as the second half of
      the same control. `justify-between` keeps the tabs where the eye expects
      them and parks the toggle at the far edge, where a control you reach for
      rarely belongs. --%>
      <div class="mt-3 flex flex-wrap items-center justify-between gap-x-3 gap-y-2">
        <%!-- The source tabs partition the list, so they are the same control
        the feed wears. Dropped where there is only one source to choose: an
        installation with the fediverse switched off. --%>
        <.post_filter_tabs
          :if={Fediverse.enabled?()}
          id="tag-source-tabs"
          active={to_string(@source)}
          event="filter-source"
          options={feed_filter_options()}
          class={nil}
        />

        <%!-- Search, sort and the date range folded away behind one line. Open,
        they are four labelled controls between the tabs and the first post — a
        post card's worth of height, spent on a narrowing almost nobody performs
        — so they start closed and open themselves when the link somebody
        followed already carries one. `data-keep-open` tells the patch loop in
        `app.js` that the disclosure's state belongs to the reader: without it
        every answer this view renders (a filter result, a live count tick from
        the remote cards) would fold the panel shut again under the cursor.

        The panel itself has to span the full row, which is what the `w-full`
        summary sibling below does: a `<details>` in a flex row is one item, so
        its open contents would otherwise be squeezed into the toggle's own
        narrow column. --%>
        <details
          id="tag-timeline-filters"
          data-keep-open
          open={filtered?(assigns)}
          class="group ml-auto [&[open]]:w-full"
        >
          <summary class="inline-flex min-h-10 cursor-pointer list-none items-center gap-1.5 text-sm font-semibold text-slate-700 hover:text-slate-900 dark:text-slate-200 dark:hover:text-white [&::-webkit-details-marker]:hidden">
          <span
            aria-hidden="true"
            class="text-base leading-none transition-transform group-open:rotate-90"
          >
            ›
          </span>
          {gettext("Filters")}
          <span
            :if={active_filters(assigns) > 0}
            data-active-filters
            class="rounded-full bg-brand-50 px-2 py-0.5 text-xs font-semibold text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"
          >
            {gettext("%{formatted} active", formatted: compact_count(active_filters(assigns)))}
          </span>
        </summary>

        <form
          id="tag-timeline-filter"
          phx-change="filter"
          phx-submit="filter"
          class="mt-2 flex flex-wrap items-end gap-3"
        >
          <div class="min-w-48 grow">
            <label for="tag-filter-q" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
              {gettext("Search")}
            </label>
            <input
              type="search"
              name="q"
              id="tag-filter-q"
              value={@query}
              phx-debounce="250"
              autocomplete="off"
              placeholder={gettext("word in a post")}
              class={input_class()}
            />
          </div>

          <div>
            <label for="tag-filter-sort" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
              {gettext("Sort")}
            </label>
            <select name="sort" id="tag-filter-sort" class={input_class()}>
              <option :for={{value, label} <- sort_options()} value={value} selected={to_string(@sort) == value}>
                {label}
              </option>
            </select>
          </div>

          <div>
            <label for="tag-filter-from" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
              {gettext("From")}
            </label>
            <input type="date" name="from" id="tag-filter-from" value={@from} class={input_class()} />
          </div>

          <div>
            <label for="tag-filter-until" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
              {gettext("Until")}
            </label>
            <input type="date" name="until" id="tag-filter-until" value={@until} class={input_class()} />
          </div>

          <button
            :if={filtered?(assigns)}
            type="button"
            phx-click="clear"
            id="tag-clear-filters"
            class="min-h-10 py-2 text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
          >
            {gettext("Clear filters")}
          </button>
        </form>
        </details>
      </div>

      <.post_list :if={!@empty?} id="tag-timeline-posts" phx-update="stream" data-filter-list class="mt-4">
        <div :for={{dom_id, entry} <- @streams.entries} id={dom_id} class={post_row_class()}>
          <%= if Posts.remote_feed_entry?(entry) do %>
            <.remote_post_card
            live?
              remote_post={entry.remote_post}
              images={entry[:images] || []}
              marks={entry[:marks]}
              viewer={@current_user}
              following?={false}
            />
          <% else %>
            <.post_thread_entry
              post={entry.post}
              viewer={@current_user}
              entry_id={entry.id}
              conn_or_socket={@socket}
              engagement={entry.engagement}
              surface={:flat}
            />
          <% end %>
        </div>
      </.post_list>

      <p :if={@empty?} id="tag-timeline-empty" class="mt-3 text-slate-600 dark:text-slate-400">
        {empty_text(assigns)}
      </p>

      <.load_more :if={@more?} class="mt-6" />
    </section>
    """
  end

  # Newest first is the default because a topic page is mostly "what is being
  # said now"; the other two are there for the reader who wants the beginning of
  # a thread of thought, or the posts that landed.
  defp sort_options do
    [
      {"newest", gettext("Newest first")},
      {"oldest", gettext("Oldest first")},
      {"likes", gettext("Most liked")}
    ]
  end

  defp filtered?(assigns), do: active_filters(assigns) > 0

  # How many of the four controls are away from their default. It decides three
  # things at once: whether the panel opens itself, whether "Clear filters" is
  # offered, and the count on the summary's badge — so a reader who folds the
  # panel back up can still see that the list below them is narrowed.
  defp active_filters(assigns) do
    named = Enum.count([assigns.query, assigns.from, assigns.until], &(not is_nil(&1)))

    if assigns.sort == :newest, do: named, else: named + 1
  end

  # Three different silences, three different lines: nothing here at all,
  # nothing on this tab, or nothing matching what the reader asked for. A single
  # "Nothing here yet" would send somebody looking for a post that is one click
  # away behind a filter they forgot about.
  defp empty_text(%{query: q, from: f, until: u} = assigns)
       when not is_nil(q) or not is_nil(f) or not is_nil(u) do
    _ = assigns
    gettext("Nothing matches that. Try a shorter search, or clear the filters.")
  end

  defp empty_text(%{source: :vutuv}), do: gettext("No posts on vutuv carry this tag yet.")

  defp empty_text(%{source: :fediverse}),
    do: gettext("No posts from other networks carry this tag yet.")

  defp empty_text(_assigns), do: gettext("No posts carry this tag yet.")
end
