defmodule VutuvWeb.PostLive.Feed do
  @moduledoc """
  The newsfeed: the composer on top, then the viewer's timeline — own posts
  plus posts *and reposts* of followed authors (visibility-filtered pull
  model, `Vutuv.Posts.feed_page/2`), cursor "Load more" at the bottom — the
  same pagination style as notifications. Entries are
  `%{id:, post:, reposted_by:, at:}` maps; repost entries render the
  "Reposted by X" line on the card.

  Above the timeline sit the **source tabs** — All / vutuv / Fediverse — the
  same segmented control the profile's post-type tabs use
  (`PostComponents.post_filter_tabs/1` with `feed_filter_options/0`). They
  partition the feed by what kind of post an entry carries, so the two named
  tabs together are "All"; the split itself lives in
  `Vutuv.Posts.feed_page/2`. The choice has no URL of its own (this LiveView
  is off-router and cannot patch) but it does outlive the visit: the tab is
  remembered on the member (`Vutuv.Posts.remember_feed_filter/2`, issue
  #1499) and read back at mount, so the next visit opens where they left off.
  Deliberately **not** broadcast to their other devices — a live tab switch
  would reload a timeline somebody else is reading from the top and take its
  pending batch, its loaded pages and its scroll position with it.

  Real-time: `Vutuv.Posts.create_post/2` broadcasts `{:new_post, …}` and
  `Vutuv.Posts.repost_post/2` `{:new_repost, …}` to the author/reposter and
  every follower over `Vutuv.Activity`. The viewer's own posts and reposts
  prepend immediately; everyone else's accumulate behind a *"Show N new
  posts"* pill (auto-inserting posts under a reading user is hostile), each
  checked against `visible_to?/2` server-side before it is even counted —
  the pill must not leak denied posts.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.PostComponents

  alias Phoenix.LiveView.JS
  alias Vutuv.Activity
  alias Vutuv.ContentFilters
  alias Vutuv.Fediverse.Handle
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Identity
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Prefs
  alias Vutuv.Social
  alias Vutuv.Tags.UserTag
  alias VutuvWeb.Live.DayClockRestream
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.Live.MountHandoff
  alias VutuvWeb.Live.PostTranslations
  alias VutuvWeb.Live.RemotePostActions
  alias VutuvWeb.Markdown
  alias VutuvWeb.UserHelpers

  # The origin's like/repost figures on a card from another network tick
  # while this page is open (issue #1283). One line, no handler.
  on_mount(VutuvWeb.Live.RemoteCounts)

  @page_size 20
  # What a source-tab press loads (see `load_source_filter/2`) — deliberately
  # smaller than a mount's page, because that press is a wait with nothing on
  # screen to read while it lasts.
  @filter_page_size 10
  # "New here" rail: how many newcomers to greet, the size of the newest-members
  # pool they are drawn out of, how many of each one's tags the card shows, and
  # how often an open feed redraws. Defined here (not beside
  # `assign_newcomers`) so `mount_feed/2` above reads a real value — a module
  # attribute is `nil` until the line that sets it.
  @newcomers 5
  @newcomer_pool 30
  @tags_per_newcomer 3
  @suggestions_refresh :timer.minutes(5)
  # "Suggested posts" rail: how many discovery posts to show at once.
  @discover_posts 5

  @impl true
  # Rendered by VutuvWeb.NewsfeedController via `live_render` (off-router, so it
  # can negotiate the agent-format siblings), exactly like UserProfileLive. An
  # off-router LiveView can't use `InitAssigns` as an `on_mount` — that hook
  # attaches a `:handle_params` hook, which it rejects — so mount mirrors it:
  # load the viewer + locale from the session the controller passes, and gate on
  # login here instead of the `:require_login` stage.
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)

    if user = socket.assigns.current_user do
      {:ok, mount_feed(socket, user)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You must be logged in to access that page"))
       |> redirect(to: ~p"/login")}
    end
  end

  defp mount_feed(socket, user) do
    # Can this browser draw the tab ticker at all? A deploy does not reload an
    # open feed — the socket reconnects to the new release and patches into a
    # document downloaded hours ago — so the question is not which release that
    # document came from but what it is able to render. The bundle answers it
    # itself: `feed_ticker` is a LiveSocket param (assets/js/app.js), so only a
    # bundle carrying the stylesheet and the hook can claim the capability.
    # Read here because connect params exist only during mount.
    socket = assign(socket, :ticker_capable?, ticker_capable?(socket))

    # The tab they left on (issue #1499). It opens the page *and* keys the
    # handoff below: the stash holds one entry per member, so two devices
    # opening /feed within its 15s TTL would otherwise let one take a page the
    # other computed for a different tab. Keyed by the filter, a mismatch is
    # simply a miss and that mount loads its own page.
    remembered = Posts.remembered_feed_filter(user)

    if connected?(socket) do
      Vutuv.Activity.subscribe(user.id)
      # Refresh the Berlin-day-relative post stamps ("09:50 Uhr" -> "Gestern,
      # 09:50 Uhr") the moment the German day rolls over at midnight.
      Vutuv.DayClock.subscribe()
      # The discovery rail reshuffles itself while the feed stays open.
      Process.send_after(self(), :refresh_suggestions, @suggestions_refresh)

      # The dead render stashed its computed page seconds ago
      # (VutuvWeb.Live.MountHandoff); take it and skip re-running the same
      # queries. Any miss (expired, consumed, a reconnect) recomputes.
      case MountHandoff.take(user.id, {:feed, remembered}) do
        {:ok, payload} -> apply_feed_payload(socket, payload)
        :error -> apply_feed_payload(socket, feed_payload(user, remembered))
      end
    else
      payload = feed_payload(user, remembered)
      MountHandoff.stash(user.id, {:feed, remembered}, payload)
      apply_feed_payload(socket, payload)
    end
  end

  # Everything a feed mount computes, as data — what the dead render hands the
  # connected mount through the single-use stash.
  defp feed_payload(user, remembered) do
    # The member's private content filters (issue #940): compiled once, applied
    # to every page, and the set of posts they chose to reveal anyway.
    compiled = ContentFilters.compile_for(user)

    # The gate before the page, because it decides which tab this mount opens
    # on: a remembered "Fediverse" whose content has gone away shows no tab bar
    # at all, and stranding them on the tab behind it would leave a timeline
    # they cannot get out of. The stored value stays untouched, so the tab
    # comes back with the content.
    source_tabs? = Posts.fediverse_feed_available?(user)
    filter = if source_tabs?, do: remembered, else: :all

    page = Posts.feed_page(user, limit: @page_size, filter: filter)
    entries = page.entries |> with_engagement(user) |> mark_filtered(compiled, user.id)

    # Read the stored draft once and hand it to the composer below, which then
    # skips its own identical query on init.
    draft = Posts.get_draft(user)

    %{
      content_filters: compiled,
      more?: page.more?,
      cursor: page.next_cursor,
      draft: draft,
      entries: entries,
      # The tab these entries were pulled for — the remembered one, or `:all`
      # where the bar is hidden.
      filter: filter,
      # Whether the source tabs are worth showing this member at all (issue
      # #1267). Read once per mount and carried on the handoff like the rest;
      # it is a fact about their whole timeline, not about the open tab, so
      # switching tabs must not recompute it.
      source_tabs?: source_tabs?,
      # The desktop discovery rail renders WITH the page: it was lazy-loaded
      # for one release (v7.200.3) and the pop-in read as slowness, so it is
      # eager again — computed here once, riding the handoff to the connected
      # mount. Phones keep it hidden by CSS; that they pay its queries on the
      # dead render is the accepted cost of the immediate desktop paint.
      rails: rail_data(user)
    }
  end

  # Everything the three rail cards render, as data. Shared by the payload
  # (mount) and the socket-side redraw helpers below, so mount and refresh
  # cannot drift.
  defp rail_data(user) do
    Map.merge(
      %{
        followed_tags: Vutuv.Tags.followed_tags(user),
        discover_posts: Posts.discover_posts(user, limit: @discover_posts)
      },
      newcomer_rail(user)
    )
  end

  # The stream is rebuilt here rather than riding the payload: a
  # %Phoenix.LiveView.LiveStream{} carries per-socket insert state that the
  # dead render already consumed, so handing the struct itself to the
  # connected socket would replay as an empty feed.
  defp apply_feed_payload(socket, payload) do
    socket
    # On-demand translations (issue #1462): the per-card view state. A map
    # means this viewer gets the controls, nil means they do not — the cards
    # read that straight off the one assign.
    |> assign(:post_translations, PostTranslations.initial_map(socket.assigns.current_user))
    |> assign(:content_filters, payload.content_filters)
    |> assign(:revealed_filters, MapSet.new())
    |> assign(:page_title, gettext("Feed"))
    # The tab this mount opened on (issue #1499) — from here on the assign is
    # the truth, and the stored column is not read again while the page lives.
    |> assign(:feed_filter, payload.filter)
    |> assign(:source_tabs?, payload.source_tabs?)
    # The named sources holding something this reader has not seen (issue
    # #1503), each one a dot on its tab. Socket state on purpose and never
    # stored: it means "since you have been looking at this page", so a mount
    # starting clean is the honest state, not a lost one.
    |> assign(:unseen_sources, MapSet.new())
    # The transient half of that (issue #1668): what landed over there, quoted
    # beside its tab for a few seconds. nil = no window open. `ticker_quiet_until`
    # is the short silence after one closes, so a burst on a bad line cannot
    # fold the bar open and shut in the same breath.
    |> assign(:tab_ticker, nil)
    |> assign(:ticker_quiet_until, nil)
    |> assign(:more?, payload.more?)
    |> assign(:cursor, payload.cursor)
    |> assign(:empty?, payload.entries == [])
    |> assign(:pending_posts, [])
    |> assign(:draft, payload.draft)
    # The composer starts collapsed to a single "What's new?" button; posting
    # (own activity arriving below) collapses it again. A stored draft opens it
    # instead (issue #1148): the composer will restore that draft, and text
    # hidden behind a collapsed panel is indistinguishable from text that was
    # thrown away. Resolved here rather than announced by the composer so the
    # disconnected render already agrees and the panel never flickers open.
    |> assign(:composer_open?, payload.draft != nil)
    # The set of entries currently on screen, kept so the midnight :day_changed
    # tick can re-render each stamp in place (streams don't retain their data).
    # Order/dupes don't matter: the refresh uses stream_insert update_only, which
    # updates existing rows where they sit and ignores ones already gone.
    |> assign(:entries, payload.entries)
    # The posts on screen we hold a photo-scan subscription for (below).
    |> assign(:photo_watch, MapSet.new())
    |> assign(payload.rails)
    |> stream_configure(:posts, dom_id: &"feed-#{&1.id}")
    |> stream(:posts, payload.entries)
    |> watch_pending_photos(payload.entries)
    |> auto_translate_entries(payload.entries)
  end

  # Every post on the page whose photo is still with the AI image scan gets a
  # subscription to its own topic, so the placecard swaps itself for the picture
  # with no reload — the arrangement the permalink's conversation already uses.
  # Deliberately not one subscription per card (a feed carries dozens): the set
  # is keyed on posts that are actually waiting, which in steady state is none
  # of them, and a verdict lands within seconds. The viewer's OWN posts would
  # reach them over their activity topic anyway; this is what covers the posts
  # they are merely reading, which is the case that sent somebody looking for a
  # reply they had just been notified about.
  defp watch_pending_photos(socket, entries) do
    if connected?(socket) do
      watched = socket.assigns.photo_watch

      fresh =
        for %{post: %Post{} = post} <- entries,
            Posts.held_for_image_check?(post),
            not MapSet.member?(watched, post.id),
            into: MapSet.new(),
            do: post.id

      Enum.each(fresh, &Posts.subscribe_post/1)
      assign(socket, :photo_watch, MapSet.union(watched, fresh))
    else
      socket
    end
  end

  # Translate mode (issue #1461): fold the page's foreign-language subjects
  # into the translations map — cached rows show at once, the rest queue and
  # swap in live. Only on the connected socket: the dead render is replaced
  # moments later, and the jobs it would enqueue are the same deduped ones.
  defp auto_translate_entries(socket, entries) do
    viewer = socket.assigns.current_user

    if connected?(socket) and PostTranslations.auto_translate?(viewer) do
      subjects = Enum.flat_map(entries, &entry_subjects/1)
      map = PostTranslations.auto_translate(socket.assigns.post_translations, subjects, viewer)
      assign(socket, :post_translations, map)
    else
      socket
    end
  end

  # What a feed entry shows that could be translated: its own post (plus the
  # nested ancestors of a reply), a cached remote post, or a remote reply.
  defp entry_subjects(entry) do
    cond do
      Posts.remote_reply_entry?(entry) -> [entry.note]
      Posts.remote_feed_entry?(entry) -> [entry.remote_post]
      true -> [entry.post | entry[:ancestors] || []]
    end
  end

  # The desktop "New here" rail: five of the newest members, drawn at random out
  # of the newest `@newcomer_pool` who show a face, minus the viewer, anyone
  # blocked either way and everyone they already follow.
  #
  # It replaces a most-followed / most-endorsed suggestion rail, and the swap is
  # the point rather than a change of source. A ranked rail shows the same
  # already-well-connected members to everybody, and the one member for whom
  # being seen actually decides whether they stay — the person who signed up
  # this morning — is exactly the one it can never reach. Drawing at random from
  # the newest instead gives every newcomer a real chance of being greeted, and
  # gives the reader a card that is never the same twice.
  #
  # The random draw is made **here**, not at render: it has to survive every
  # re-render of the page, and only a fresh draw (a reshuffle, the periodic
  # tick, a new mount) may change who is on it.
  defp newcomer_rail(user) do
    # Never suggest a member the viewer blocked (or who blocked them): the follow
    # would be refused as :blocked and the suggestion would just reappear.
    blocked = Social.blocked_user_ids(user.id)

    candidates =
      @newcomer_pool
      |> Social.newest_members_with_avatar()
      |> Enum.reject(&(&1.id == user.id or MapSet.member?(blocked, &1.id)))

    following = UserHelpers.following_map(user, candidates)

    users =
      candidates
      |> Enum.reject(&Map.has_key?(following, &1.id))
      |> Enum.take_random(@newcomers)

    %{
      newcomers: newcomer_rows(users),
      # Every newcomer on a fresh draw is by construction someone the viewer
      # does not follow, so every pill starts in its "Follow" state. The map
      # fills as they welcome people (`assign_following/1`), which is what keeps
      # a greeted row on the card instead of making the person vanish.
      following_by_id: %{}
    }
  end

  # The drawn members as finished rows: the member, the muted meta line under
  # their name, and their tag sample with a count of what it leaves out.
  # Assembled here rather than looked up out of three parallel maps in the
  # markup, so the template renders a row instead of joining tables and each
  # batched query is asked exactly once per draw.
  #
  # The tags are drawn at random rather than in the profile's
  # most-endorsed-first order on purpose: a member who signed up this week has
  # no endorsements at all, so that order collapses to alphabetical and the card
  # would show the same three tags of theirs forever. Three is a glance at what
  # somebody is about, which is all this card is for — the whole list is one
  # click away on their profile.
  defp newcomer_rows(users) do
    work_info = UserHelpers.work_information_map(users, 60)
    tags_by_user = Vutuv.Tags.user_tags_by_user(users)

    Enum.map(users, fn user ->
      tags = Map.get(tags_by_user, user.id, [])
      sample = Enum.take_random(tags, @tags_per_newcomer)

      %{
        user: user,
        work: Map.get(work_info, user.id, ""),
        tags: sample,
        more: length(tags) - length(sample)
      }
    end)
  end

  defp assign_newcomers(socket) do
    socket
    |> assign(newcomer_rail(socket.assigns.current_user))
    |> assign_following()
  end

  # Which members on the card the viewer follows right now, in one query — the
  # same `%{followee_id => follow_id}` map every other people listing renders
  # its follow pills from. Recomputed after a welcome (and after taking one
  # back) rather than patched by hand, so a pill cannot drift from the follow
  # table.
  defp assign_following(socket) do
    users = Enum.map(socket.assigns.newcomers, & &1.user)
    follows = UserHelpers.following_map(socket.assigns.current_user, users)
    assign(socket, :following_by_id, follows)
  end

  # The desktop "Tags you follow" rail (issue #872): the member's tag
  # subscriptions as chips, each with a reload-free ✕ unfollow. Refreshed
  # whenever the follow set changes (an unfollow here, or a follow/unfollow made
  # on a tag page while this feed is open — see the :tag_follows_changed handler).
  defp assign_followed_tags(socket) do
    assign(socket, :followed_tags, Vutuv.Tags.followed_tags(socket.assigns.current_user))
  end

  # The ↻ both rail cards wear: one control, one glyph, one set of colours.
  # Rendered by "New here" and by "Suggested posts", which want the identical
  # affordance ("show me another draw") and differ only in what they say and
  # which event they push.
  attr(:id, :string, required: true)
  attr(:event, :string, required: true)
  attr(:label, :string, required: true)

  defp reshuffle_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      title={@label}
      aria-label={@label}
      class="text-slate-500 transition hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-200"
    >
      <svg
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
        stroke-width="1.5"
        stroke="currentColor"
        class="h-4 w-4"
        aria-hidden="true"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182m0-4.991v4.99"
        />
      </svg>
    </button>
    """
  end

  # The rail's "Suggested posts" card: a random handful of recent public posts
  # by same-language members the viewer does not follow — discovery beyond the
  # follow graph, like "New here" but for content (the draw itself lives in
  # `Posts.discover_posts/2`). Re-run by the reload button, the periodic
  # refresh tick and every follow (a just-followed author's post is no longer
  # a discovery).
  defp assign_discover_posts(socket) do
    posts = Posts.discover_posts(socket.assigns.current_user, limit: @discover_posts)
    assign(socket, :discover_posts, posts)
  end

  # The card's post body. Rendered through the exact same Markdown formatter as
  # a normal post preview (`VutuvWeb.Markdown.render_preview/2` → `render_post/2`)
  # so the rail shows formatted text — headings flattened to bold via
  # `.markdown--post`, @mentions and #hashtags linked — instead of the raw
  # Markdown source. The source is block-cut at the preview limit to keep the
  # rail DOM light; the visible cut is the six-line CSS clamp (`line-clamp-6`)
  # on the wrapper, so we drop the truncation flag here.
  defp discover_body(body) do
    {html, _truncated?} = VutuvWeb.Markdown.render_preview(body, [])
    html
  end

  # Pre-load the action-bar engagement AND the viewer's follow edge to each
  # author for the whole page in one query each, and hang them on each entry, so
  # the per-card Actions LiveViews don't each run their own query (was one query
  # per post) and the card's mute toggle knows its follow id + state without a
  # per-row lookup. A threaded reply nests the whole conversation it answers as
  # full cards, so every ancestor post id joins the same engagement batch and
  # each entry carries a `%{post_id => engagement}` submap for those cards' bars.
  # Live-arriving single posts carry `engagement: nil` (falls back to the bar's
  # own query) and get their follow edge in `insert_entry/3`.
  # The one-line stand-in for a content-filtered post (issue #940): says which
  # filter hid it and offers to show it anyway, in place.
  attr(:pattern, :string, required: true)

  attr(:key, :string,
    required: true,
    doc: "what the reveal set remembers this entry by (`filter_key/1`), not always a post id"
  )

  defp filtered_placeholder(assigns) do
    ~H"""
    <div
      data-filtered-post={@pattern}
      class="flex flex-wrap items-center gap-x-2 gap-y-1 rounded-2xl bg-slate-50 px-4 py-3 text-sm text-slate-600 ring-1 ring-slate-200 dark:bg-slate-900/50 dark:text-slate-400 dark:ring-slate-800"
    >
      <span>
        {gettext("Hidden: matches your filter")}
        <code class="rounded bg-slate-200 px-1.5 py-0.5 font-mono text-xs text-slate-800 dark:bg-slate-800 dark:text-slate-200">{@pattern}</code>
      </span>
      <button
        type="button"
        phx-click="reveal_filter"
        phx-value-id={@key}
        class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {gettext("Show anyway")}
      </button>
    </div>
    """
  end

  defp with_engagement(entries, user) do
    ancestor_ids = fn entry -> Enum.map(entry[:ancestors] || [], & &1.id) end

    # A cached post from another network (issue #1161) has no author here, so
    # there is nothing to like, nothing to mute and nobody to follow: it is kept
    # out of both batch reads, and then passed through untouched. Decorating in
    # place rather than splitting the list keeps the order the page arrived in,
    # so nothing has to be sorted back together afterwards.
    local = local_entries(entries)

    engagement =
      local
      |> Enum.flat_map(fn entry -> [entry.post.id | ancestor_ids.(entry)] end)
      |> Enum.uniq()
      |> Posts.post_engagement_map(user)

    follows =
      local
      |> Enum.map(& &1.post.user_id)
      |> Enum.uniq()
      |> then(&Social.follow_edges(user.id, &1))

    Enum.map(entries, fn entry ->
      if Posts.remote_feed_entry?(entry) do
        entry
      else
        entry
        |> Map.put(:engagement, engagement[entry.post.id])
        |> Map.put(:ancestor_engagement, Map.take(engagement, ancestor_ids.(entry)))
        |> Map.put(:viewer_follow, follows[entry.post.user_id])
      end
    end)
  end

  # A card's Translate tap (issue #1462): authorize + queue (or serve the
  # cache), then re-render the one streamed card the state concerns.
  @impl true
  def handle_event("translate", %{"kind" => kind, "id" => id}, socket) do
    case PostTranslations.request(socket.assigns.current_user, kind, id) do
      {:ok, key, state} ->
        {:noreply,
         socket
         |> update(:post_translations, &Map.put(&1, key, state))
         |> restream_translated(key)}

      :denied ->
        {:noreply, socket}
    end
  end

  def handle_event("show-original", %{"kind" => kind, "id" => id}, socket) do
    case PostTranslations.show_original(socket.assigns.post_translations, kind, id) do
      :ignore ->
        {:noreply, socket}

      {key, map} ->
        {:noreply, socket |> assign(:post_translations, map) |> restream_translated(key)}
    end
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    page =
      Posts.feed_page(socket.assigns.current_user,
        limit: @page_size,
        cursor: socket.assigns.cursor,
        filter: socket.assigns.feed_filter
      )

    # A post shown higher up (as a newer repost, or nested in a shown thread)
    # must not reappear on an older page: `feed_page/2` dedups within a page but
    # can't see the ones already on screen. The higher card already carries the
    # complete follow-scoped roster, so dropping the older duplicate loses
    # nothing. Filter before the engagement batch so it queries only survivors.
    shown = shown_post_ids(socket.assigns.entries)

    fresh =
      Enum.reject(page.entries, fn entry ->
        not Posts.remote_feed_entry?(entry) and MapSet.member?(shown, entry.post.id)
      end)

    entries =
      fresh
      |> with_engagement(socket.assigns.current_user)
      |> mark_filtered(socket.assigns.content_filters, socket.assigns.current_user.id)

    {:noreply,
     socket
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> update(:entries, &(&1 ++ entries))
     |> stream(:posts, entries, at: -1)
     |> watch_pending_photos(entries)
     |> auto_translate_entries(entries)}
  end

  # A source tab (All / vutuv / Fediverse). The tab decides which sources the
  # query pulls from, so it cannot be applied to the page already on screen —
  # the timeline reloads from the top.
  def handle_event("filter-source", %{"type" => type}, socket) do
    filter = Posts.normalize_feed_filter(type)
    # Remembered for the next visit (issue #1499) — here and not in
    # `load_source_filter/2`, which the arrival of the member's own post also
    # calls to pull the feed back to "All". That fallback is the code's doing,
    # not theirs, and must not overwrite the tab they chose.
    Posts.remember_feed_filter(socket.assigns.current_user, filter)

    {:noreply, load_source_filter(socket, filter)}
  end

  def handle_event("open-composer", _params, socket) do
    # Both triggers open the same composer — there are no modes. The camera
    # button additionally clicks the composer's "Add photos" control
    # client-side (a JS.dispatch chained onto its phx-click), so the photo
    # picker opens in the same gesture.
    {:noreply, assign(socket, :composer_open?, true)}
  end

  # The composer's corner ✕ (feed compose only) bubbles up here to collapse it.
  def handle_event("close-composer", _params, socket) do
    {:noreply, assign(socket, :composer_open?, false)}
  end

  # "Show anyway" on a content-filtered post (issue #940): reveal it in place,
  # no reload. The reveal set survives a midnight restream, so the post stays
  # open. Re-stream just this one entry so its placeholder swaps to the card.
  def handle_event("reveal_filter", %{"id" => key}, socket) do
    case Enum.find(socket.assigns.entries, &(filter_key(&1) == key)) do
      nil ->
        {:noreply, socket}

      entry ->
        {:noreply,
         socket
         |> update(:revealed_filters, &MapSet.put(&1, key))
         |> stream_insert(:posts, entry, update_only: true)}
    end
  end

  # A member reports a cached post from another network. It is deleted at once
  # (`Vutuv.Fediverse.report_remote_post/2`) — this is a cache of something that
  # still exists at its origin, so there is no case and no freezer — and the
  # row leaves the feed in the same round trip.
  def handle_event("report-remote-post", %{"id" => id}, socket) do
    RemotePostActions.report(socket, id, &drop_remote_entry(&1, id))
  end

  # "Not this account today": the private, reversible lever beside Report. The
  # follow survives; its posts leave this feed, so every row from that account
  # goes in the same round trip rather than lingering until the next reload.
  def handle_event("mute-remote-account", %{"id" => account_id}, socket) do
    RemotePostActions.mute(socket, account_id, &drop_remote_entries_of(&1, account_id))
  end

  # And the same menu's way out that lasts. The rows leave for the same reason —
  # they were here because of that follow — and the cached posts themselves go
  # with it once nobody here follows the account any more.
  def handle_event("unfollow-remote-account", %{"id" => account_id}, socket) do
    RemotePostActions.unfollow(socket, account_id, &drop_remote_entries_of(&1, account_id))
  end

  # The "New here" card's Follow button: welcome the newcomer with no reload.
  #
  # The row deliberately **stays** afterwards, flipped to its "Following" state,
  # instead of being dropped and replaced by the next candidate the way the
  # ranked rail this replaced did. Greeting somebody and watching them vanish
  # reads as if the click undid something; on a card whose whole subject is
  # saying hello, the visible ✓ is the answer. A fresh draw (reshuffle, the
  # periodic tick, the next visit) leaves them out again, since by then the
  # viewer follows them.
  #
  # The posts rail redraws — the new followee's post may be in it, and a followed
  # author is no longer a discovery.
  def handle_event("follow", %{"followee" => followee_id}, socket) do
    # Every refusal — a tampered id, a block, following yourself, an edge that
    # already exists — comes back as an error tuple rather than a raise, so
    # re-reading the follow table afterwards simply leaves the pill where it was.
    Social.follow(socket.assigns.current_user, followee_id)

    {:noreply, socket |> assign_following() |> assign_discover_posts()}
  end

  # The other half of the same pill: a welcome taken back before the page is
  # left. Scoped to the viewer by `unfollow!/2`, so a tampered id can only ever
  # drop an edge they own.
  def handle_event("unfollow", %{"id" => follow_id}, socket) do
    Social.unfollow!(socket.assigns.current_user.id, follow_id)
    {:noreply, assign_following(socket)}
  end

  # The "Tags you follow" rail's ✕: unfollow the tag with no reload, then redraw
  # the rail so the chip drops. The already-shown posts stay put — like
  # unfollowing a person, the change only shapes the next feed load.
  def handle_event("unfollow_tag", %{"id" => tag_id}, socket) do
    Vutuv.Tags.unfollow_tag(socket.assigns.current_user, tag_id)
    {:noreply, assign_followed_tags(socket)}
  end

  # The "New here" card's reload button: greet five other newcomers, with
  # another three tags each.
  def handle_event("reshuffle-newcomers", _params, socket) do
    {:noreply, assign_newcomers(socket)}
  end

  # The "Suggested posts" card's reload button: draw 5 fresh random ones.
  def handle_event("reshuffle-discover", _params, socket) do
    {:noreply, assign_discover_posts(socket)}
  end

  # The window ran out in the browser. It has already hidden itself there, so
  # this only clears the server's copy — and starts the silence — which is what
  # keeps a later patch from putting the quote back on screen.
  def handle_event("hide-tab-ticker", _params, socket) do
    {:noreply, hide_ticker(socket)}
  end

  def handle_event("show-new", _params, socket) do
    pending = socket.assigns.pending_posts

    # Revealing the batch is the member choosing to look at exactly these
    # posts, so a notification whose subject is one of them (the answer to
    # their post, an answer elsewhere in their thread, the post naming them)
    # is old news the moment the pill unfolds: the bell recounts over the
    # :notifications_changed broadcast. Harmless for posts nobody notified
    # about (the mark is a row no tally consults), and the pattern skips any
    # future pending entry without a local post to mark.
    Activity.mark_posts_seen(
      socket.assigns.current_user.id,
      for(%{post: %{id: post_id}} <- pending, do: post_id)
    )

    socket =
      pending
      # Oldest pending first, so the newest ends up on top.
      |> Enum.reverse()
      |> Enum.reduce(socket, fn entry, socket ->
        socket
        |> stream_insert(:posts, entry, at: 0)
        |> prune_threaded_parent(entry)
      end)
      |> update(:entries, &(pending ++ &1))
      |> watch_pending_photos(pending)
      |> assign(:pending_posts, [])
      |> assign(:empty?, false)

    {:noreply, socket}
  end

  # Load the timeline for one source tab, replacing whatever is on screen
  # (`reset: true`). The pending batch is dropped with it rather than
  # re-filtered: the fresh page is newest-first from the top, so it already
  # carries everything that was waiting behind the pill.
  #
  # **Half a page, not a whole one** (`@filter_page_size`): a mount is a page
  # load and pays for a full page once, but a tab press happens mid-visit and
  # its twenty rendered cards are the bulk of the second the member waits on a
  # slow line — for a screen that holds three or four. `more?` comes from the
  # same query, so the "Load more" button below picks the rest up at the full
  # page size.
  defp load_source_filter(socket, filter) do
    user = socket.assigns.current_user
    page = Posts.feed_page(user, limit: @filter_page_size, filter: filter)

    entries =
      page.entries
      |> with_engagement(user)
      |> mark_filtered(socket.assigns.content_filters, user.id)

    socket
    |> assign(:feed_filter, filter)
    |> assign(:more?, page.more?)
    |> assign(:cursor, page.next_cursor)
    |> assign(:empty?, entries == [])
    |> assign(:pending_posts, [])
    |> assign(:entries, entries)
    |> clear_unseen(filter)
    |> close_ticker()
    |> stream(:posts, entries, reset: true)
    |> watch_pending_photos(entries)
  end

  # Landing on a tab clears its dot — the page above is newest-first from the
  # top, so whatever it was pointing at has now been seen. "All" clears both,
  # because it shows both; a named tab clears only itself, so a dot waiting on
  # the other one survives the trip.
  defp clear_unseen(socket, :all), do: assign(socket, :unseen_sources, MapSet.new())

  defp clear_unseen(socket, source),
    do: update(socket, :unseen_sources, &MapSet.delete(&1, source))

  @impl true
  def handle_info({:new_post, %{post_id: post_id, author_id: author_id}}, socket) do
    post = Posts.get_post(post_id)

    entry =
      post &&
        %{
          id: "post-#{post.id}",
          post: post,
          reposted_by: nil,
          reposters: [],
          at: post.inserted_at,
          engagement: nil
        }

    insert_entry(socket, entry, author_id)
  end

  # A repost arrived over the viewer's activity topic. The fan-out only reaches
  # a reposter's *followers* (or the reposter), so the reposter always belongs
  # in this viewer's roster. Where the post already sits decides what happens:
  # fold the new face into an on-screen card's stack (in place, no reshuffle —
  # the card only climbs on the next reload), or into a card still behind the
  # pill; skip it silently when the post is already visible nested inside a
  # shown thread; otherwise it is new and takes the usual own/pill path.
  def handle_info(
        {:new_repost, %{repost_id: repost_id, post_id: post_id, reposter_id: reposter_id}},
        socket
      ) do
    reposter = Vutuv.Repo.get(Vutuv.Accounts.User, reposter_id)

    cond do
      is_nil(reposter) ->
        {:noreply, socket}

      shown = find_by_post_id(socket.assigns.entries, post_id) ->
        {:noreply, restack_shown(socket, shown, reposter)}

      MapSet.member?(shown_post_ids(socket.assigns.entries), post_id) ->
        {:noreply, socket}

      pending = Enum.find(socket.assigns.pending_posts, &(&1.post.id == post_id)) ->
        {:noreply, restack_pending(socket, pending, reposter)}

      true ->
        post = Posts.get_post(post_id)

        entry =
          post &&
            %{
              id: "repost-#{repost_id}",
              post: post,
              reposted_by: reposter,
              reposters: [reposter],
              at: NaiveDateTime.utc_now(:second),
              engagement: nil
            }

        insert_entry(socket, entry, reposter_id)
    end
  end

  # A post was deleted: drop its entry from the stream and from any pending
  # batch behind the pill. Reposts of it are keyed by repost id, so their card
  # shell survives until reload, but its action bar empties via the post topic.
  def handle_info({:post_deleted, %{post_id: post_id}}, socket) do
    {:noreply,
     socket
     |> stream_delete_by_dom_id(:posts, "feed-post-#{post_id}")
     |> update(:pending_posts, &Enum.reject(&1, fn entry -> entry.post.id == post_id end))}
  end

  # Periodic reshuffle of the "New here" and "Suggested posts" rails: draw a
  # fresh random slate of not-yet-followed newcomers and posts and reschedule
  # the next tick. Cheap (an id-ordered pool scan, a follow-edge query, the tag
  # batch and the pooled posts draw, all small), so a 5-minute cadence on an
  # open feed is fine. It is also what keeps the cards' relative wording honest
  # on a page left open across midnight: the next tick redraws
  # "joined today" as "joined yesterday" without a reload.
  def handle_info(:refresh_suggestions, socket) do
    Process.send_after(self(), :refresh_suggestions, @suggestions_refresh)
    {:noreply, socket |> assign_newcomers() |> assign_discover_posts()}
  end

  # Something landed through the fediverse (issue #1503) — a followed account
  # posted or boosted, or somebody here passed a remote post or reply on. Unlike
  # `{:new_post, …}` this carries no entry, because whether that write reaches
  # THIS reader depends on their mutes, their follow states, the audience and
  # their language filter; so the nudge only says "look", and the feed asks its
  # own sources (`Posts.feed_source_since?/3`).
  #
  # Only the tab the reader is NOT on can be dotted, which is why "All" ignores
  # this outright: it shows both halves, so nothing landed elsewhere. A member
  # with no tab bar has nowhere to put a dot and pays no query either.
  def handle_info({:remote_feed_arrival, %{at: at}}, socket) do
    {:noreply, dot_other_tab(socket, at)}
  end

  # The viewer followed / unfollowed a tag elsewhere (a tag page in another tab,
  # issue #872): redraw the "Tags you follow" rail so an open feed reflects it
  # live. Posts already streamed stay; the new tag's posts arrive on the next
  # load, like a fresh person-follow.
  def handle_info({:tag_follows_changed, _}, socket) do
    {:noreply, assign_followed_tags(socket)}
  end

  # The Berlin day rolled over (Vutuv.DayClock at midnight): re-render every
  # shown post's stamp so "today" wording becomes "Gestern" and yesterday's
  # falls back to a full date. Shared with notifications + the saved hub; see
  # VutuvWeb.Live.DayClockRestream.
  def handle_info(:day_changed, socket) do
    {:noreply, DayClockRestream.restream(socket, :entries, :posts)}
  end

  # A post's link screenshot finished capturing (fan-out reaches the viewer over
  # their activity topic, like :new_post): if the post is on the page, refresh
  # its card in place so the screenshot appears with no reload.
  def handle_info({:post_screenshot_ready, %{post_id: post_id}}, socket) do
    {:noreply, refresh_shown_post(socket, post_id)}
  end

  # The author removed a bad link screenshot: refresh the card so it drops.
  def handle_info({:post_screenshot_removed, %{post_id: post_id}}, socket) do
    {:noreply, refresh_shown_post(socket, post_id)}
  end

  # A photo of the author's post cleared the AI image scan (issue #1104):
  # refresh the card so the picture appears and the "checking your photos…"
  # line counts down and finally disappears — the author watches it finish
  # instead of reloading to find out.
  def handle_info({:post_images_settled, %{post_id: post_id}}, socket) do
    {:noreply, refresh_shown_post(socket, post_id)}
  end

  # The worker finished a translation this reader asked for (issue #1462):
  # swap it into the one card, or clear the pending line on a failure.
  def handle_info({:translation_ready, translation}, socket) do
    viewer = socket.assigns.current_user

    case PostTranslations.apply_ready(socket.assigns.post_translations, translation, viewer) do
      :ignore ->
        {:noreply, socket}

      {key, map} ->
        {:noreply, socket |> assign(:post_translations, map) |> restream_translated(key)}
    end
  end

  def handle_info({:translation_failed, key, target}, socket) do
    viewer = socket.assigns.current_user

    case PostTranslations.apply_failed(socket.assigns.post_translations, key, target, viewer) do
      :ignore ->
        {:noreply, socket}

      {key, map} ->
        {:noreply, socket |> assign(:post_translations, map) |> restream_translated(key)}
    end
  end

  # The composer says it holds a draft, so show it (issue #1130). Two moments
  # send this: the first characters of a normal compose (the panel is already
  # open, so the assign is a no-op), and the `validate` LiveView's form recovery
  # replays after a reconnect — which is the one that matters. A reconnect
  # re-mounts this LiveView, and `composer_open?` is plain socket state, so the
  # panel collapses while the text stays in it: the author comes back to their
  # tab, finds the form gone and has no reason to believe the draft survived.
  def handle_info({:composer_drafting, _id}, socket) do
    {:noreply, assign(socket, :composer_open?, true)}
  end

  # Photo mode's ✕ discarded the draft inside the component; the panel
  # collapses with it (the component cannot reach this assign itself).
  def handle_info({:composer_discarded, _id}, socket) do
    {:noreply, assign(socket, :composer_open?, false)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # The dot half of `{:remote_feed_arrival, …}` above. Three cheap refusals
  # before the query: "All" has no other tab, a member without the tab bar has
  # nowhere to show one, and a tab already dotted has nothing to learn.
  defp dot_other_tab(socket, at) do
    source = other_source(socket.assigns.feed_filter)

    cond do
      is_nil(source) or not socket.assigns.source_tabs? ->
        socket

      # A window already open for this tab only needs the *fact* that another
      # one landed — the count replaces the quote from the second on — so it
      # skips the query the same way the plain dot used to.
      ticking?(socket, source) ->
        count_ticker(socket)

      # Nothing left to learn: the dot is already there and no quote is due
      # (the member switched it off, or the last window only just closed).
      MapSet.member?(socket.assigns.unseen_sources, source) and not ticker_due?(socket) ->
        socket

      entry = Posts.newest_source_entry(socket.assigns.current_user, source, at) ->
        socket |> mark_unseen(source) |> open_ticker(source, entry)

      true ->
        socket
    end
  end

  # The other named tab — nil on "All", which is both of them at once.
  defp other_source(:vutuv), do: :fediverse
  defp other_source(:fediverse), do: :vutuv
  defp other_source(_all), do: nil

  # The tab values carrying a dot: the named sources holding something unseen,
  # and only those. "All" holds the same posts, so a dot there was true and read
  # as a third place with news of its own. The component drops the dot on
  # whichever tab is active, so this never has to know which one that is.
  defp unseen_tabs(sources), do: Enum.map(sources, &to_string/1)

  # Swap in the post's now-screenshot-carrying copy and re-stream the entry in
  # place (update_only, so an off-page id is a harmless no-op). The entry's other
  # fields — engagement, follow edge, repost roster — are preserved.
  defp refresh_shown_post(socket, post_id) do
    with entry when not is_nil(entry) <- find_by_post_id(socket.assigns.entries, post_id),
         post when not is_nil(post) <- Posts.get_post(post_id) do
      updated = %{entry | post: post}

      socket
      |> update(:entries, &replace_entry(&1, updated))
      |> stream_insert(:posts, updated, update_only: true)
    else
      _ -> socket
    end
  end

  # Swap the refreshed entry into the retained list by its stable entry id.
  defp replace_entry(entries, updated), do: replace_entry(entries, updated.id, updated)

  # Own activity (this or another session) appears immediately; other
  # people's waits behind the pill — and only when the post is visible.
  defp insert_entry(socket, nil, _actor_id), do: {:noreply, socket}

  defp insert_entry(socket, entry, actor_id) do
    user = socket.assigns.current_user

    cond do
      # The author must see what they just wrote. Every live arrival carries a
      # vutuv post, so on the Fediverse tab there is no row to put it in — the
      # feed switches back to All and reloads rather than swallowing the post,
      # which from the composer reads as the post having been lost.
      actor_id == user.id and not Posts.feed_filter_accepts?(socket.assigns.feed_filter, entry) ->
        {:noreply,
         socket
         |> assign(:composer_open?, false)
         |> load_source_filter(:all)}

      actor_id == user.id ->
        decorated = decorate(entry, user, socket)

        {:noreply,
         socket
         |> assign(:empty?, false)
         # The viewer just posted (this or another session): collapse the composer.
         |> assign(:composer_open?, false)
         |> update(:entries, &[decorated | &1])
         |> stream_insert(:posts, decorated, at: 0)
         |> prune_threaded_parent(entry)}

      # Mirror the pull path's blocked-author filter: a third party's repost
      # must not carry a blocked author's post into the feed (blocking already
      # severed the direct follow). visible_to?/2 alone never checks blocks.
      Social.blocked_between?(user.id, entry.post.user_id) ->
        {:noreply, socket}

      # Visibility is asked FIRST, and the order is the whole correctness of
      # the dot below (issue #1503): the tab check used to come first and drop
      # the arrival, which cost nothing while the answer was "do nothing" and
      # would now light a tab for a post this reader is not allowed to read.
      not Posts.visible_to?(entry.post, user) ->
        {:noreply, socket}

      # A post nobody on this tab asked for must not be counted by the pill
      # either: the pill's whole promise is that clicking it shows those posts
      # right here.
      Posts.feed_filter_accepts?(socket.assigns.feed_filter, entry) ->
        {:noreply, update(socket, :pending_posts, &[decorate(entry, user, socket) | &1])}

      # It belongs on a tab the reader is not looking at, so say so there
      # rather than dropping it: a dot, not a count — the point is that
      # something is over there, and the tab reloads from the top anyway.
      true ->
        source = entry_source(entry)
        {:noreply, socket |> mark_unseen(source) |> open_or_count_ticker(source, entry)}
    end
  end

  # Which named tab an entry belongs to — the two are a partition, so the one
  # question `remote_feed_entry?/1` answers decides it.
  defp entry_source(entry) do
    if Posts.remote_feed_entry?(entry), do: :fediverse, else: :vutuv
  end

  defp mark_unseen(socket, source),
    do: update(socket, :unseen_sources, &MapSet.put(&1, source))

  ## ── The tab ticker (issue #1668) ──
  #
  # The dot says *that* something landed on the tab you are not on. The ticker
  # says *what*, quoting the arrival's author and first words beside that tab —
  # and then goes, because the bar belongs to the tabs. Three rules carry it:
  #
  # 1. **One quote per window.** A second arrival inside the window cannot
  #    replace the first (both would stand for less time than it takes to read
  #    one) and cannot queue behind it (ten arrivals would hold the bar open
  #    for a minute and a half), so the quote gives up and becomes a count.
  #    The clock is **not** restarted by it: the window belongs to the moment,
  #    not to the last thing that landed, or a busy source owns the bar.
  # 2. **The browser owns the clock.** See the `FeedTicker` hook — a window
  #    counted out on the server would include the trip out, and a hide that
  #    never arrives would leave the quote standing forever.
  # 3. **A silence after each window** (`:feed_ticker_cooldown_ms`), longer
  #    than the fold-away animation. Posts do not arrive evenly on a slow line
  #    — a reconnect delivers a backlog at once — and without it the bar would
  #    close and reopen in the same breath. What lands in the silence still
  #    gets its dot.
  #
  # Only ever one tab at a time: `other_source/1` is nil on "All", and the two
  # named tabs partition the feed, so the reader is on one of them and
  # everything that is not theirs belongs to the other. A third source would be
  # the first thing to break that, and would need a rule for two open windows.

  # An arrival on a tab the reader is not on, from the path that carries the
  # entry: extend the open window or start a new one.
  defp open_or_count_ticker(socket, source, entry) do
    if ticking?(socket, source),
      do: count_ticker(socket),
      else: open_ticker(socket, source, entry)
  end

  defp open_ticker(socket, source, entry) do
    with true <- ticker_due?(socket),
         %{} = teaser <- ticker_teaser(socket, entry) do
      assign(socket, :tab_ticker, %{
        tab: to_string(source),
        who: teaser.who,
        text: teaser.text,
        count: 1,
        seconds: Prefs.get(socket.assigns.current_user, :feed_tab_ticker_seconds),
        # What tells the hook a *new* window started, so it restarts its clock.
        # Stays put while the count climbs, which is how rule 1 above holds.
        id: System.unique_integer([:positive]),
        aria: ticker_aria(source, teaser.who, 1)
      })
    else
      _ -> socket
    end
  end

  defp count_ticker(socket) do
    update(socket, :tab_ticker, fn ticker ->
      count = ticker.count + 1

      %{
        ticker
        | count: count,
          aria: ticker_aria(ticker.tab, ticker.who, count)
      }
    end)
  end

  # The member went to the tab themselves, so the window has done its job —
  # and no silence is owed: they acted, nothing flickered at them.
  defp close_ticker(socket), do: assign(socket, :tab_ticker, nil)

  # The window ran out (the hook says so). Its silence starts here.
  defp hide_ticker(socket) do
    socket
    |> assign(:tab_ticker, nil)
    |> assign(:ticker_quiet_until, System.monotonic_time(:millisecond) + ticker_cooldown_ms())
  end

  defp ticking?(socket, source) do
    case socket.assigns.tab_ticker do
      %{tab: tab} -> tab == to_string(source)
      _ -> false
    end
  end

  # Whether a fresh window may open: the member wants quotes at all, the tab
  # bar exists to put one in, the last window's silence is over — and the
  # browser can render a quote at all.
  #
  # That last one is the deploy case, and it is the one thing on this page that
  # an old document cannot survive. Everything else the feed patches in is
  # markup whose CSS that browser already has; the ticker is new markup with a
  # stylesheet and a hook of its own, so on a feed left open across the v7.347.0
  # deploy the quote drew as an unstyled 200-character paragraph across the tab
  # bar that no clock ever took away (the `FeedTicker` hook was not in that
  # bundle either). Such a browser keeps the dot, which is markup from #1503 and
  # renders fine, and skips the quote until the next full page load.
  defp ticker_due?(socket) do
    socket.assigns.source_tabs? and is_nil(socket.assigns.tab_ticker) and
      socket.assigns.ticker_capable? and
      Prefs.get(socket.assigns.current_user, :feed_tab_ticker?) and not quiet?(socket)
  end

  # v7.347.1 asked `static_changed?/1` here, which answers the wider question
  # "is anything in this document older than the running release?" — true after
  # *every* asset deploy, so from the second one on it refused browsers that had
  # been carrying the ticker all along. v7.348.0 was that second deploy, and the
  # feature read as broken until a reload. A capability the bundle asserts about
  # itself cannot go stale that way: it travels with the hook, and a bundle old
  # enough to lack the hook has no way to send it.
  #
  # Retire this param together with the `FeedTicker` hook.
  defp ticker_capable?(socket) do
    case get_connect_params(socket) do
      %{"feed_ticker" => true} -> true
      _ -> false
    end
  end

  defp quiet?(socket) do
    case socket.assigns.ticker_quiet_until do
      nil -> false
      until -> System.monotonic_time(:millisecond) < until
    end
  end

  defp ticker_cooldown_ms, do: Application.get_env(:vutuv, :feed_ticker_cooldown_ms, 2_000)

  # Who wrote it and what it opens with. Returns nil for an entry this reader
  # has muted by content filter: the quote would put the very word they
  # silenced into the bar, and `decorate/3` — which stamps `:filtered_by` — only
  # runs on the branch for the tab they *are* on.
  defp ticker_teaser(socket, entry) do
    viewer = socket.assigns.current_user

    if filtered_pattern(entry, socket.assigns.content_filters, viewer.id) do
      nil
    else
      %{who: ticker_who(entry), text: ticker_text(entry)}
    end
  end

  # The handle without its server (`Handle.short/1`): the tab beside the quote
  # already says "Fediverse", and the domain would take half the line.
  defp ticker_who(entry) do
    cond do
      Posts.remote_reply_entry?(entry) ->
        Handle.short(Handle.display(entry.note.handle, entry.note.actor_uri))

      Posts.remote_feed_entry?(entry) ->
        Handle.short(RemoteAccount.display_handle(entry.remote_post.remote_account))

      true ->
        case Posts.author(entry.post) do
          nil -> nil
          author -> local_who(author)
        end
    end
  end

  # A page that never claimed a root handle has none to show, so it is named.
  defp local_who(author) do
    case Identity.handle(author) do
      handle when is_binary(handle) -> "@" <> handle
      _ -> Identity.display_name(author)
    end
  end

  defp ticker_text(entry) do
    cond do
      Posts.remote_reply_entry?(entry) -> one_line(entry.note.content_text)
      Posts.remote_feed_entry?(entry) -> one_line(entry.remote_post.content_text)
      true -> one_line(Markdown.to_preview_line(entry.post.body))
    end
  end

  # A quote is one line whatever the body did. The cap keeps a long post out of
  # the payload; where the line is actually cut is the bar's width, in CSS.
  defp one_line(text) when is_binary(text) do
    case text |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 200) do
      "" -> nil
      line -> line
    end
  end

  defp one_line(_text), do: nil

  # Naming the tab with a colon rather than a preposition, and one string for
  # both tabs: "new in the Fediverse" and "new on vutuv" do not share a German
  # sentence, so a %{source} placeholder inside a prepositional phrase would be
  # wrong in one of them. Screen readers only: what the eye gets is the tint.
  defp ticker_aria(source, who, 1) when is_binary(who),
    do: gettext("%{source}: new post from %{who}", source: source_name(source), who: who)

  defp ticker_aria(source, _who, 1),
    do: gettext("%{source}: new post", source: source_name(source))

  defp ticker_aria(source, _who, count) do
    ngettext(
      "%{source}: %{formatted} new post",
      "%{source}: %{formatted} new posts",
      count,
      source: source_name(source),
      formatted: compact_count(count)
    )
  end

  # The tab's own label, so the two never drift apart.
  defp source_name(source) do
    tab = to_string(source)

    Enum.find_value(feed_filter_options(), tab, fn {value, label} ->
      value == tab && label
    end)
  end

  # A newly streamed reply renders the post it answers inline (the threaded
  # card), so drop the parent's standalone row — from the stream and from any
  # pending batch behind the pill — to avoid showing it twice. The pull path
  # (`Posts.feed_page/2`) dedups the same way on reload. A no-op for a
  # non-reply, and harmless when the parent isn't on the page
  # (`stream_delete_by_dom_id` ignores an absent id). Targets the parent's
  # own-post row (`feed-post-<id>`); a repost of the parent self-corrects on
  # the next reload.
  defp prune_threaded_parent(socket, entry) do
    case Posts.reply_ref_state(entry.post) do
      {:parent, parent} ->
        socket
        |> stream_delete_by_dom_id(:posts, "feed-post-#{parent.id}")
        |> update(:pending_posts, &Enum.reject(&1, fn e -> e.post.id == parent.id end))

      _ ->
        socket
    end
  end

  # Attach the viewer's follow edge (so the card's mute toggle works on a
  # live-arrived post too — nil for an own post, no self-follow) and the
  # action-bar engagement, both queried in this process. The bar component
  # renders straight from the entry's engagement, so a live-arrived card never
  # queries during render (which would race the sandbox in tests). Only the
  # two branches that keep the entry pay for it — a blocked or denied post is
  # dropped before either query runs. A live-arrived reply nests only its direct
  # parent (one level, whose bar self-loads); the full visible chain reassembles
  # on the next reload / "Load more" (which run through `collapse_threads/1`).
  defp decorate(entry, user, socket) do
    entry
    |> Map.put(:viewer_follow, Social.follow_edge(user.id, entry.post.user_id))
    |> Map.put(:engagement, Posts.post_engagement(entry.post.id, user.id))
    |> mark_one(socket.assigns.content_filters, user.id)
  end

  # Content filters (issue #940): stamp each entry with the pattern that hides it
  # (`:filtered_by`), or leave it clear. Never the viewer's own posts. A no-op
  # for the vast majority who mute nothing, so the feed pays for it only when a
  # filter exists.
  defp mark_filtered(entries, compiled, viewer_id) do
    if ContentFilters.any?(compiled),
      do: Enum.map(entries, &mark_one(&1, compiled, viewer_id)),
      else: entries
  end

  defp mark_one(entry, compiled, viewer_id) do
    Map.put(entry, :filtered_by, filtered_pattern(entry, compiled, viewer_id))
  end

  defp filtered_pattern(entry, compiled, viewer_id) do
    cond do
      # A cached post from another network (issue #1161) is filtered on its
      # plain text: the member muted a word because they do not want to read it,
      # and where it was written changes nothing about that.
      Posts.remote_feed_entry?(entry) ->
        ContentFilters.filtered_text(remote_entry_text(entry), compiled)

      # Never the member's own posts. A remote post cannot reach this arm: it has
      # no author here, so the exemption has nothing to match on.
      entry.post.user_id == viewer_id ->
        nil

      true ->
        ContentFilters.filtered_pattern(entry.post, compiled)
    end
  end

  # What the reveal set remembers. A vutuv post is keyed by its own id (so the
  # same post stays revealed when it is restreamed), a cached post from another
  # network (issue #1161) by its row id — it is not a `%Post{}` and has no post
  # id to key on.
  defp filter_key(entry) do
    cond do
      Posts.remote_reply_entry?(entry) -> entry.note.id
      Posts.remote_feed_entry?(entry) -> entry.remote_post.id
      true -> entry.post.id
    end
  end

  # Whether the reader's filters currently hide this entry: it matched one, and
  # they have not opened it. The single expression the row's three renderings
  # branch on, so the placeholder and the card it stands in for cannot both show
  # (or both vanish).
  defp hidden_by_filter?(entry, revealed),
    do: entry[:filtered_by] != nil and filter_key(entry) not in revealed

  # A reported or muted cached post leaves the feed in the same round trip, so
  # the reader never looks at a row that is no longer theirs to see.
  #
  # `empty?` is recomputed because it gates the whole timeline container: a
  # reader whose feed held nothing but the account they just muted would
  # otherwise be left looking at an empty white card instead of the "nothing
  # here yet" message. Caught in a browser, not by the tests — none of them
  # emptied a feed this way.
  # Every card by one remote account, off the page in this round trip — what
  # both Mute and Unfollow leave behind. A reshared **reply** carries no
  # `remote_post`, so it is asked about through `remote_reply_entry?/1` first
  # rather than reached for and found nil.
  defp drop_remote_entries_of(socket, account_id) do
    socket.assigns.entries
    |> Enum.filter(fn entry ->
      Posts.remote_feed_entry?(entry) and not Posts.remote_reply_entry?(entry) and
        entry.remote_post.remote_account_id == account_id
    end)
    |> Enum.reduce(socket, &drop_remote_entry(&2, &1.remote_post.id))
  end

  defp drop_remote_entry(socket, remote_post_id) do
    # By each entry's own id, not by a rebuilt one. The same cached post can be
    # on the page twice — once because the reader follows its author (issue
    # #1161, `remote-<post id>`) and once because somebody here reshared it
    # (issue #1166, `remote-repost-<repost id>`) — and a report deletes the row
    # for everybody, so every row showing it has to go. Guessing the dom id
    # left the reshared copy on screen until the next reload.
    going = Enum.filter(socket.assigns.entries, &remote_entry?(&1, remote_post_id))

    socket
    |> update(:entries, &(&1 -- going))
    |> then(fn socket ->
      Enum.reduce(going, socket, &stream_delete_by_dom_id(&2, :posts, "feed-#{&1.id}"))
    end)
    |> then(&assign(&1, :empty?, &1.assigns.entries == [] and &1.assigns.pending_posts == []))
  end

  # Both toggles on a remote card, one shape: the heart (issue #1164) and the
  # reshare (issue #1166). The entry is re-inserted into the stream rather than
  # an assign being flipped: a stream item redraws only when its own entry is
  # handed back, which is also why the state rides the entry. `:flash` is an
  # `{outcome, message}` the act announces itself with when it really happened.
  # The text a content filter matches on, whichever remote shape the row is.
  defp remote_entry_text(entry) do
    if Posts.remote_reply_entry?(entry),
      do: entry.note.content_text,
      else: entry.remote_post.content_text
  end

  # "This row is the cached post with that id" — the one predicate the three
  # scans over `:entries` that single a remote post out all read from.
  defp remote_entry?(entry, remote_post_id),
    do:
      Posts.remote_feed_entry?(entry) and not Posts.remote_reply_entry?(entry) and
        entry.remote_post.id == remote_post_id

  # The entries carrying a vutuv post. A cached post from another network has
  # `post: nil`, so every batch read and every scan that reaches for
  # `entry.post` goes through this (or `find_by_post_id/2`) first.
  defp local_entries(entries), do: Enum.reject(entries, &Posts.remote_feed_entry?/1)

  # Re-render the one streamed card a translation state change concerns; a
  # subject not on screen is a harmless no-op (update_only). A local post may
  # sit in an entry as the leaf OR as a nested ancestor — either way the
  # entry re-renders with the current translations map.
  defp restream_translated(socket, key) do
    case find_by_translation_key(socket.assigns.entries, key) do
      nil -> socket
      entry -> stream_insert(socket, :posts, entry, update_only: true)
    end
  end

  defp find_by_translation_key(entries, key) do
    # Reuses entry_subjects/1, so "what can this entry translate" is spelled
    # once — the reverse lookup cannot drift from the auto-translate sweep.
    Enum.find(entries, fn entry ->
      Enum.any?(entry_subjects(entry), &(PostTranslations.subject_key(&1) == key))
    end)
  end

  defp find_by_post_id(entries, post_id) do
    Enum.find(entries, fn entry ->
      not Posts.remote_feed_entry?(entry) and entry.post.id == post_id
    end)
  end

  # Every post id currently represented on screen — each streamed entry's own
  # post plus every ancestor it nests — so a live or paged repost of an
  # already-shown post updates that card (or drops) instead of duplicating it.
  defp shown_post_ids(entries) do
    for entry <- local_entries(entries),
        post <- [entry.post | entry[:ancestors] || []],
        into: MapSet.new(),
        do: post.id
  end

  # Fold a new reposter into an on-screen card's avatar stack, in place: keep
  # the entry's stream id (so the row updates where it sits, no jump) and just
  # grow the roster + rename the newest reposter. A repost we already counted
  # (idempotent re-broadcast) is a no-op.
  defp restack_shown(socket, entry, reposter) do
    case restacked_entry(entry, reposter) do
      nil ->
        socket

      updated ->
        socket
        |> update(:entries, &replace_entry(&1, entry.id, updated))
        |> stream_insert(:posts, updated, update_only: true)
    end
  end

  # Same fold for a card still waiting behind the "show new" pill: it has no
  # stream row yet, so only its pending map grows (it reveals with the full
  # stack when the pill is clicked).
  defp restack_pending(socket, pending, reposter) do
    case restacked_entry(pending, reposter) do
      nil -> socket
      updated -> update(socket, :pending_posts, &replace_entry(&1, pending.id, updated))
    end
  end

  # nil when this reposter is already counted (idempotent re-broadcast), else the
  # entry with the reposter folded into its roster and named as the newest.
  defp restacked_entry(entry, reposter) do
    unless Enum.any?(entry.reposters, &(&1.id == reposter.id)) do
      %{entry | reposters: [reposter | entry.reposters], reposted_by: reposter}
    end
  end

  defp replace_entry(entries, id, updated) do
    Enum.map(entries, fn entry -> if entry.id == id, do: updated, else: entry end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="feed" class="py-6">
      <%!-- Two columns on desktop: the feed, plus a discovery rail that uses the
      otherwise-empty side space. The rail is desktop-only (the grid collapses
      to one column under md, and the rail is hidden anyway). --%>
      <div class="grid gap-6 md:grid-cols-3">
        <%!-- min-w-0: below md the grid is a single implicit `auto` track that
        respects this column's min-content, so a long `truncate` descendant (a
        threaded reply's parent-excerpt) would otherwise force the column — and
        the whole page — wider than a phone viewport. --%>
        <%!-- `data-filter-scope` pairs the source tabs below with the timeline
        they govern: while a tab press is in flight the stylesheet dims
        everything marked `data-filter-list` inside this container, so the press
        is answered on the spot instead of a round trip later. Both markers have
        to stay under this one element. --%>
        <div data-filter-scope class="min-w-0 space-y-4 md:col-span-2">
          <%!-- No visible headline: the top nav already marks Feed as active,
          so the page opens with the compose tile (like the profile's Beiträge
          card) and the h1 stays for screen readers only. The Likes/Bookmarks
          links that used to balance the headline were redundant — both live
          in the avatar menu and as tabs on the saved hub. --%>
          <h1 class="sr-only">{gettext("Feed")}</h1>

          <%!-- Collapsed by default: the shared avatar-card trigger (see
          <.composer_trigger>), revealed via phx-click, plus the camera button
          that opens the very same composer and client-side clicks its "Add
          photos" control (the label exists in the hidden panel, so the
          native picker opens in the same gesture; if a browser refuses the
          scripted click, the opened composer still shows the control). The
          composer stays mounted (just hidden) so a half-typed draft survives
          a background feed re-render; posting or the composer's corner ✕
          collapses it. A reconnect re-mounts this LiveView and would
          collapse it under a draft, so a drafting composer re-opens itself
          (:composer_drafting). --%>
          <%!-- Hidden rather than dropped while the composer is open, and the
          display class is picked by ONE condition so the two can never both
          land on the element (the #880 trap: `hidden` loses the cascade to a
          `flex` beside it). A conditional
          element ABOVE the editor is the caret-killer of #1200: when it comes
          and goes, morphdom relocates the following siblings to restore their
          order — a removeChild + insertBefore of #composer-panel, measured —
          and re-parenting a `contenteditable` blurs it, so a member typing
          when the composer collapses or re-opens loses the caret and the
          keystrokes after it. --%>
          <div
            id="composer-trigger"
            class={[
              if(@composer_open?, do: "hidden", else: "flex"),
              "items-center gap-2 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800"
            ]}
          >
            <.composer_trigger
              viewer={@current_user}
              surface={:flat}
              avatar_size="md"
              class="min-w-0 flex-1"
              id="open-composer"
              phx-click="open-composer"
            >
              {gettext("Write a post")}
            </.composer_trigger>
            <button
              type="button"
              id="open-photo-composer"
              phx-click={
                JS.push("open-composer")
                |> JS.dispatch("click", to: "#composer-add-photos input[type=file]")
              }
              title={gettext("Post photos")}
              aria-label={gettext("Post photos")}
              class="inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-slate-100 text-slate-600 hover:bg-slate-200 hover:text-slate-900 dark:bg-slate-800 dark:text-slate-300 dark:hover:bg-slate-700 dark:hover:text-slate-100"
            >
              <svg
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
                aria-hidden="true"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M6.827 6.175A2.31 2.31 0 0 1 5.186 7.23c-.38.054-.757.112-1.134.175C2.999 7.58 2.25 8.507 2.25 9.574V18a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9.574c0-1.067-.75-1.994-1.802-2.169a47.865 47.865 0 0 0-1.134-.175 2.31 2.31 0 0 1-1.64-1.055l-.822-1.316a2.192 2.192 0 0 0-1.736-1.039 48.774 48.774 0 0 0-5.232 0 2.192 2.192 0 0 0-1.736 1.039l-.821 1.316Z"
                />
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M16.5 12.75a4.5 4.5 0 1 1-9 0 4.5 4.5 0 0 1 9 0Z"
                />
              </svg>
            </button>
          </div>

          <%!-- The panel is just the composer component; its corner ✕ bubbles a
          `close-composer` up to this LiveView, and it also collapses on its own
          after the viewer posts (see the {:new_post, …} handler). --%>
          <div id="composer-panel" class={[!@composer_open? && "hidden"]}>
            <.live_component
              module={VutuvWeb.PostLive.Composer}
              id="composer"
              current_user={@current_user}
              acting_as={@acting_as}
              post={nil}
              preloaded_draft={{:loaded, @draft}}
            />
          </div>

          <%!-- The source tabs, the same segmented control the profile's
          post-type tabs use — shown only to a member the fediverse actually
          reaches (issue #1267). For everyone else the three tabs are one
          timeline under three names: "Fediverse" can never fill, so "vutuv"
          is just "All" again. `Posts.fediverse_feed_available?/1` asks the
          tab's own sources, so this cannot drift from what it would show, and
          it is false on an installation with the fediverse switched off. A
          feed with fediverse content in it is never empty, so no separate
          empty-feed check is needed — and an empty *tab* keeps the bar, or
          there would be no way back.

          A tab holding something that landed while the reader was on another
          one wears a coral dot (issue #1503), cleared by going there. --%>
          <.post_filter_tabs
            :if={@source_tabs?}
            id="feed-source-tabs"
            active={to_string(@feed_filter)}
            event="filter-source"
            options={feed_filter_options()}
            unseen={unseen_tabs(@unseen_sources)}
            ticker={@tab_ticker}
          />

          <div :if={@pending_posts != []} class="text-center">
            <.button id="show-new-posts" variant="secondary" phx-click="show-new">
              {ngettext(
                "Show %{formatted} new post",
                "Show %{formatted} new posts",
                length(@pending_posts),
                formatted: compact_count(length(@pending_posts))
              )}
            </.button>
          </div>

          <%!-- The timeline is one card of flat divide-y rows — the same
          container and shared <.post_thread_entry> the profile Posts section
          uses, so the feed and a profile read as one UX (a reply nests the post
          it answers inline instead of the old flat "Replying to @handle"
          banner). Gated on @empty? so an empty feed shows the message below
          rather than a blank card; every live insert flips @empty? in the same
          diff, so the container is present whenever there is (or just became)
          content. --%>
          <.post_list :if={!@empty?} id="feed-posts" phx-update="stream" data-filter-list>
            <%!-- Three ways a row can render, in precedence order: hidden by a
            filter, a cached post from another network, or a vutuv post. Named
            once each in one branch, so no pair of conditions has to be kept
            complementary by hand. --%>
            <div :for={{dom_id, entry} <- @streams.posts} id={dom_id} class={post_row_class()}>
              <%= cond do %>
                <% hidden_by_filter?(entry, @revealed_filters) -> %>
                  <%!-- A content-filtered post (issue #940) collapses to a line
                  the reader can still open, instead of vanishing (a silently
                  shorter feed confuses and breaks reply threads). --%>
                  <.filtered_placeholder pattern={entry.filtered_by} key={filter_key(entry)} />
                <% Posts.remote_reply_entry?(entry) -> %>
                  <%!-- A reply from another network that somebody here passed
                  on (issue #1275). The same card the conversation draws, with
                  the reshare line above it — what is new is the sharing. --%>
                  <.remote_reply_card
                    note={entry.note}
                    viewer={@current_user}
                    marks={entry[:marks]}
                    reposted_by={entry.reposted_by}
                    translations={@post_translations}
                    live?
                  />
                <% Posts.remote_feed_entry?(entry) -> %>
                  <%!-- A post by an account the reader follows out there: the
                  same remote skin the reply cards wear, one federating heart
                  (issue #1164; replies and boosts are #1165/#1166), and its own
                  report control. --%>
                  <.remote_post_card
                    live?
                    remote_post={entry.remote_post}
                    images={entry[:images] || []}
                    marks={entry[:marks]}
                    reposted_by={entry[:reposted_by]}
                    boosted_by={entry[:boosted_by]}
                    following?={entry[:following?] == true}
                    viewer={@current_user}
                    translations={@post_translations}
                  />
                <% true -> %>
                  <%!-- A vutuv member's post that a followed account out there
                  re-shared (issue #1167). The local card, with the line that
                  says who passed it on above it — this is how members get
                  discovered through the outside network. --%>
                  <.boosted_banner :if={entry[:boosted_by]} account={entry.boosted_by} />
                  <.post_thread_entry
                    post={entry.post}
                    viewer={@current_user}
                    acting_as={@acting_as}
                    viewer_follow={entry[:viewer_follow]}
                    ancestors={entry[:ancestors]}
                    ancestor_engagement={entry[:ancestor_engagement] || %{}}
                    reposted_by={entry.reposted_by}
                    reposters={entry[:reposters]}
                    entry_id={entry.id}
                    conn_or_socket={@socket}
                    engagement={entry.engagement}
                    translations={@post_translations}
                    surface={:flat}
                  />
              <% end %>
            </div>
          </.post_list>

          <%!-- An empty *tab* says which half of the feed is missing; an empty
          feed keeps the general invitation, which is the one that helps a new
          member. --%>
          <p
            :if={@empty? && @pending_posts == [] && @feed_filter != :all}
            class="text-slate-600 dark:text-slate-400"
          >
            {feed_filter_empty_text(to_string(@feed_filter))}
          </p>

          <p
            :if={@empty? && @pending_posts == [] && @feed_filter == :all}
            class="text-slate-600 dark:text-slate-400"
          >
            {gettext("Nothing here yet. Follow people to fill your feed, or write your first post.")}
            <.link
              navigate={~p"/listings/most_followed_users"}
              class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
            >
              {gettext("Discover people to follow")}
            </.link>
          </p>

          <.load_more :if={@more?} />

          <%!-- On mobile (where the desktop rail is hidden) the "Other formats"
          card drops to the bottom of the page; the discovery rail stays
          desktop-only. The links are the feed's own agent siblings (/feed.md
          etc.) — the viewer's timeline in another format, not their profile. --%>
          <.other_formats_card
            base_path="/feed"
            locale={@locale}
            id="feed-other-formats-mobile"
            class="md:hidden"
          />
        </div>

        <%!-- Desktop-only rail (hidden under md, where the grid is one column):
        the tags the viewer follows, the "New here" welcome card, the suggested
        posts, and the "Other formats" card the profile shows too. Rendered WITH
        the page on purpose: a lazily loaded rail popped in after the paint and
        read as slowness (the v7.200.3 laziness was undone). --%>
        <aside id="feed-rail" class="hidden space-y-6 md:block">
          <%!-- "Tags you follow" (issue #872): the viewer's tag subscriptions,
          each a chip linking to the tag page with a reload-free ✕ unfollow. Sits
          at the top of the rail because it is the viewer's own state and the
          easiest place to unsubscribe. Shown only once at least one tag is
          followed. --%>
          <.card :if={@followed_tags != []} id="followed-tags">
            <.section_title class="mb-4">{gettext("Tags you follow")}</.section_title>
            <div class="flex flex-wrap gap-2">
              <span
                :for={tag <- @followed_tags}
                id={"followed-tag-#{tag.id}"}
                class="inline-flex max-w-full items-center gap-1 rounded-lg bg-brand-50 py-1 pl-3 pr-1.5 text-sm font-medium text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"
              >
                <.link navigate={~p"/tags/#{tag}"} class="min-w-0 truncate hover:underline">
                  <span aria-hidden="true">#</span>{tag.name || tag.slug}
                </.link>
                <button
                  type="button"
                  phx-click="unfollow_tag"
                  phx-value-id={tag.id}
                  title={gettext("Unfollow")}
                  aria-label={gettext("Unfollow #%{tag}", tag: tag.name || tag.slug)}
                  class="flex h-4 w-4 flex-shrink-0 items-center justify-center rounded-full leading-none text-brand-500 transition hover:bg-brand-100 hover:text-brand-800 dark:text-brand-300 dark:hover:bg-brand-800 dark:hover:text-brand-100"
                >
                  <span aria-hidden="true">×</span>
                </button>
              </span>
            </div>
          </.card>

          <%!-- "New here": five of the newest members, drawn at random and shown
          with their face, how long they have been here and three of their tags.
          It replaces a most-followed suggestion rail, whose problem was not its
          data but its arithmetic: a ranking shows the same well-connected
          members to everybody, and the one person for whom being seen decides
          whether they come back at all — the one who signed up this morning —
          is precisely the one it can never surface. The card asks for a
          greeting rather than a recommendation, which is a thing a reader can
          give away for free and a newcomer can feel. --%>
          <.card :if={@newcomers != []} id="newcomers">
            <div class="mb-1 flex items-center justify-between gap-3">
              <.section_title>{gettext("New here")}</.section_title>
              <.reshuffle_button
                id="newcomers-reshuffle"
                event="reshuffle-newcomers"
                label={gettext("Greet other members")}
              />
            </div>
            <%!-- "A few of" carries the whole draw: these are not *the* newest
            members in order, they are a random handful out of them, and a
            sentence that says "the most recently joined" promises a ranking the
            ↻ visibly contradicts. It also stays true on a quiet installation
            (an intranet vutuv with forty members), where the newest member may
            have been here for months. --%>
            <p class="mb-4 text-sm text-slate-600 dark:text-slate-400">
              {gettext("A few of the newest members. Following them is a warm welcome.")}
            </p>
            <ul class="space-y-4">
              <li :for={row <- @newcomers} id={"newcomer-#{row.user.id}"} class="flex items-start gap-3">
                <.link href={~p"/#{row.user}"} class="shrink-0">
                  <.avatar
                    user={row.user}
                    size="sm"
                    alt={gettext("Profile picture of %{name}", name: UserHelpers.full_name(row.user))}
                  />
                </.link>
                <div class="min-w-0 flex-1">
                  <%!-- Only the name shares a line with the Follow pill. The
                  meta line below it runs the full column width instead, which
                  is what makes it readable at all: the pill is 5.5rem wide in a
                  rail a third of the page across, so beside it "seit 9 Tagen
                  dabei · Privatier @ JL" was cut mid-word. --%>
                  <div class="flex items-start gap-2">
                    <.link
                      href={~p"/#{row.user}"}
                      class="min-w-0 flex-1 truncate text-sm font-medium text-slate-800 hover:text-brand-700 dark:text-slate-100"
                    >
                      {UserHelpers.full_name(row.user)}
                    </.link>
                    <.follow_button
                      variant="text"
                      follower_id={@current_user.id}
                      followee_id={row.user.id}
                      follow_id={Map.get(@following_by_id, row.user.id)}
                      live?
                    />
                  </div>
                  <%!-- The job title, when there is one. It used to lead with
                  how long the member had been here ("seit 3 Tagen dabei · …"),
                  which was interesting and cost a third of the row for a fact
                  the card's own heading already makes — five rows deep, that
                  bought nothing (Stefan, 2026-08-24). A member with no job
                  filled in, which most have not on their first days, simply
                  gets no line rather than an empty one. --%>
                  <p
                    :if={row.work != ""}
                    class="mb-0 mt-0.5 truncate text-xs text-slate-600 dark:text-slate-400"
                  >
                    {row.work}
                  </p>
                  <%!-- Three tags, at rail scale, each a link to that topic:
                  enough to be curious about somebody, never their whole
                  profile. The +N is what the sample leaves out and leads to the
                  rest of them; it is the tag-specific plural the member
                  directory already uses, not a bare "+3". --%>
                  <div
                    :if={row.tags != []}
                    data-newcomer-tags={row.user.id}
                    class="mt-1.5 flex flex-wrap items-center gap-1"
                  >
                    <.chip
                      :for={user_tag <- row.tags}
                      size="sm"
                      navigate={~p"/tags/#{UserTag.tag(user_tag)}"}
                    >
                      <span aria-hidden="true">#</span>{UserTag.truncated_name(user_tag)}
                    </.chip>
                    <.link
                      :if={row.more > 0}
                      navigate={~p"/#{row.user}/tags"}
                      class="text-xs font-medium text-slate-600 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
                    >
                      {ngettext("+1 more tag", "+%{formatted} more tags", row.more,
                        formatted: compact_count(row.more)
                      )}
                    </.link>
                  </div>
                </div>
              </li>
            </ul>
            <.card_footer_link href={~p"/system/members"}>
              {gettext("All members")}
            </.card_footer_link>
          </.card>

          <%!-- "Suggested posts": a random handful of recent public posts by
          same-language members the viewer doesn't follow — discovery beyond
          the follow graph, like "Who to follow" but for content. Compact rows
          (avatar + name + the Markdown-formatted, hyphenated body clamped at
          six lines), each a stretched link to the post so a click anywhere
          opens it — not full post cards, an action bar and gallery don't fit a
          rail. The reload button draws 5 fresh ones with no page reload. --%>
          <.card :if={@discover_posts != []} id="discover-posts">
            <div class="mb-4 flex items-center justify-between gap-3">
              <.section_title>{gettext("Suggested posts")}</.section_title>
              <.reshuffle_button
                id="discover-reshuffle"
                event="reshuffle-discover"
                label={gettext("Show other posts")}
              />
            </div>
            <ul class="divide-y divide-slate-100 dark:divide-slate-800">
              <li
                :for={post <- @discover_posts}
                class="relative flex items-start gap-3 py-3 first:pt-0 last:pb-0"
              >
                <%!-- Stretched link: a click anywhere on the row that is not
                itself a link (the body text, the avatar, the gaps) opens the
                post. The author-name link and any inline @mention/#hashtag/URL
                links in the body sit above it (relative + z-20) so they keep
                their own targets. --%>
                <.link
                  href={Posts.path(post)}
                  aria-label={gettext("View post")}
                  class="absolute inset-0 z-10"
                >
                </.link>
                <.avatar user={post.user} size="sm" shape="circle" presence />
                <div class="min-w-0">
                  <p class="mb-0 text-sm">
                    <.link
                      href={~p"/#{post.user}"}
                      class="relative z-20 font-medium text-slate-800 hover:text-brand-700 dark:text-slate-100"
                    >
                      {UserHelpers.full_name(post.user)}
                    </.link>
                    <span class="text-slate-600 dark:text-slate-400">
                      · <.post_time at={post.inserted_at} />
                    </span>
                  </p>
                  <%!-- Formatted like a normal post preview (Markdown, six-line
                  clamp). The browser hyphenates the narrow rail column (long
                  German compounds) via the `.markdown--post` hyphens seam, set
                  to `auto` on desktop too. Inline links float above the
                  stretched link (`[&_a]:relative` + z-20); the plain text falls
                  through to it, so clicking it opens the post. --%>
                  <div
                    class="markdown markdown--post mt-1 line-clamp-6 text-sm text-slate-700 dark:text-slate-300 [&_a]:relative [&_a]:z-20"
                    style="--post-hyphens-desktop:auto;--post-hyphens-mobile:auto"
                  >
                    {discover_body(post.body)}
                  </div>
                </div>
              </li>
            </ul>
          </.card>

          <.other_formats_card base_path="/feed" locale={@locale} id="feed-other-formats" />
        </aside>
      </div>
    </div>
    """
  end
end
