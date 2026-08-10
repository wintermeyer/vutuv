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
    # The same three answers, in the same words, as the feed's report control:
    # one act, described once, wherever a member meets a cached post.
    case Fediverse.report_remote_post(id, socket.assigns.current_user) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Thank you. Our copy was deleted right away."))
         |> drop_remote_entry(id)}

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You have reported a lot today. Please try again tomorrow.")
         )}

      {:error, :not_found} ->
        {:noreply, drop_remote_entry(socket, id)}
    end
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
    <section id="tag-timeline" class="mt-6">
      <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
          {gettext("Posts with this tag")}
        </h2>
        <p data-timeline-total class="text-sm text-slate-600 dark:text-slate-400">
          {ngettext("%{formatted} post", "%{formatted} posts", @total, formatted: compact_count(@total))}
        </p>
      </div>

      <%!-- The source tabs partition the list, so they are the same control the
      feed wears. Dropped where there is only one source to choose: an
      installation with the fediverse switched off. --%>
      <.post_filter_tabs
        :if={Fediverse.enabled?()}
        id="tag-source-tabs"
        active={to_string(@source)}
        event="filter-source"
        options={feed_filter_options()}
        class="mt-3"
      />

      <form
        id="tag-timeline-filter"
        phx-change="filter"
        phx-submit="filter"
        class="mt-3 flex flex-wrap items-end gap-3"
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

      <.post_list :if={!@empty?} id="tag-timeline-posts" phx-update="stream" data-post-list class="mt-3">
        <div :for={{dom_id, entry} <- @streams.entries} id={dom_id} class={post_row_class()}>
          <%= if Posts.remote_feed_entry?(entry) do %>
            <.remote_post_card
            live?
              remote_post={entry.remote_post}
              images={entry[:images] || []}
              marks={entry[:marks]}
              viewer={@current_user}
              mute?={false}
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

  defp filtered?(assigns) do
    not is_nil(assigns.query) or not is_nil(assigns.from) or not is_nil(assigns.until) or
      assigns.sort != :newest
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
