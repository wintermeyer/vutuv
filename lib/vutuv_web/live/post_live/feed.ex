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
  # The desktop rail reuses the profile's compact user row (the "Other formats"
  # card is a global VutuvWeb.UI component, imported already).
  import VutuvWeb.UserHTML, only: [user_row: 1]

  alias Phoenix.LiveView.JS
  alias Vutuv.Activity
  alias Vutuv.ContentFilters
  alias Vutuv.Fediverse
  alias Vutuv.Posts
  alias Vutuv.Social
  alias VutuvWeb.Live.DayClockRestream
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.Live.MountHandoff
  alias VutuvWeb.Live.PostTranslations
  alias VutuvWeb.Live.RemotePostActions
  alias VutuvWeb.UserHelpers

  # The origin's like/repost figures on a card from another network tick
  # while this page is open (issue #1283). One line, no handler.
  on_mount(VutuvWeb.Live.RemoteCounts)

  @page_size 20
  # "Who to follow" rail: how many suggestions to show, the size of the popular
  # pool we shuffle them out of, and how often an open feed reshuffles. Defined
  # here (not beside `assign_who_to_follow`) so `mount_feed/2` above reads a real
  # value — a module attribute is `nil` until the line that sets it.
  @who_to_follow 6
  @suggestion_pool 60
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
      who_to_follow_rail(user)
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
    |> assign(payload.rails)
    |> stream_configure(:posts, dom_id: &"feed-#{&1.id}")
    |> stream(:posts, payload.entries)
    |> auto_translate_entries(payload.entries)
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

  # The desktop "Who to follow" rail: a randomized handful of the most-followed
  # members the viewer does *not* already follow (nor the viewer themselves) —
  # listing someone you already follow as a suggestion makes no sense. We pull a
  # generous pool of popular members, drop the viewer and everyone they follow,
  # then *shuffle* what's left and take `@who_to_follow`. The shuffle means each
  # visit (and the periodic `:refresh_suggestions` tick) surfaces a different
  # slate instead of the same fixed top-6 every time. Following one (live, no
  # reload) recomputes the rail, so the new followee drops out and a fresh draw
  # fills the slot.
  defp who_to_follow_rail(user) do
    # Never suggest a member the viewer blocked (or who blocked them): the follow
    # would be refused as :blocked and the suggestion would just reappear.
    blocked = Social.blocked_user_ids(user.id)

    # Lead the rail with members endorsed for the tags the viewer follows (issue
    # #872, the "recommendations show people with the tag" half), then fill from
    # the popular pool. The tag people keep their endorsement order at the front;
    # the popular pool is shuffled behind them so a long-lived session (and the
    # periodic reshuffle) still varies once the tag people run out — and when the
    # viewer follows no tags, tag_people is [] and this is the old shuffled pool.
    tag_people = Vutuv.Tags.people_for_followed_tags(user, @who_to_follow * 2)
    popular = Enum.shuffle(Social.most_followed_users(@suggestion_pool))

    candidates =
      (tag_people ++ popular)
      |> Enum.uniq_by(& &1.id)
      |> Enum.reject(&(&1.id == user.id or MapSet.member?(blocked, &1.id)))

    following = UserHelpers.following_map(user, candidates)

    users =
      candidates
      |> Enum.reject(&Map.has_key?(following, &1.id))
      |> Enum.take(@who_to_follow)

    %{
      recommended_users: users,
      work_info_by_id: UserHelpers.work_information_map(users, 60),
      # The two-line samples under each row: a name and a job title say who
      # someone is, not what they write about, and the rail is asking the viewer
      # to bet on the latter. Redrawn with the slate, so a reshuffle (or a follow
      # dropping a row) brings the new members' posts with it.
      suggested_posts_by_id: Posts.recent_posts_by_authors(users, user),
      # Every suggestion is by construction someone the viewer does not follow,
      # so the follow buttons all render the "Follow" state from an empty map.
      following_by_id: %{}
    }
  end

  defp assign_who_to_follow(socket) do
    assign(socket, who_to_follow_rail(socket.assigns.current_user))
  end

  # The desktop "Tags you follow" rail (issue #872): the member's tag
  # subscriptions as chips, each with a reload-free ✕ unfollow. Refreshed
  # whenever the follow set changes (an unfollow here, or a follow/unfollow made
  # on a tag page while this feed is open — see the :tag_follows_changed handler).
  defp assign_followed_tags(socket) do
    assign(socket, :followed_tags, Vutuv.Tags.followed_tags(socket.assigns.current_user))
  end

  # The rail's "Suggested posts" card: a random handful of recent public posts
  # by same-language members the viewer does not follow — the post-shaped twin
  # of the "Who to follow" suggestions (the draw itself lives in
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
    :ok = Fediverse.set_remote_follow_mute(socket.assigns.current_user, account_id, true)

    muted =
      Enum.filter(socket.assigns.entries, fn entry ->
        Posts.remote_feed_entry?(entry) and not Posts.remote_reply_entry?(entry) and
          entry.remote_post.remote_account_id == account_id
      end)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Muted. You still follow them; their posts leave your feed."))
     |> then(fn socket ->
       Enum.reduce(muted, socket, &drop_remote_entry(&2, &1.remote_post.id))
     end)}
  end

  # The rail's "Follow" button (user_row live?): follow with no reload, then
  # recompute the rail so the new followee drops out (we only suggest members
  # the viewer doesn't already follow) and the next candidate fills the slot.
  # The posts rail redraws too — the new followee's post may be in it, and a
  # followed author is no longer a discovery.
  def handle_event("follow", %{"followee" => followee_id}, socket) do
    me = socket.assigns.current_user

    if me && me.id != followee_id, do: Social.follow(me, followee_id)

    {:noreply, socket |> assign_who_to_follow() |> assign_discover_posts()}
  end

  # The "Tags you follow" rail's ✕: unfollow the tag with no reload, then redraw
  # the rail (the chip drops) and the "Who to follow" rail (which leads with
  # people from followed tags). The already-shown posts stay put — like
  # unfollowing a person, the change only shapes the next feed load.
  def handle_event("unfollow_tag", %{"id" => tag_id}, socket) do
    Vutuv.Tags.unfollow_tag(socket.assigns.current_user, tag_id)
    {:noreply, socket |> assign_followed_tags() |> assign_who_to_follow()}
  end

  # The "Suggested posts" card's reload button: draw 5 fresh random ones.
  def handle_event("reshuffle-discover", _params, socket) do
    {:noreply, assign_discover_posts(socket)}
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
      |> assign(:pending_posts, [])
      |> assign(:empty?, false)

    {:noreply, socket}
  end

  # Load the timeline for one source tab, replacing whatever is on screen
  # (`reset: true`). The pending batch is dropped with it rather than
  # re-filtered: the fresh page is newest-first from the top, so it already
  # carries everything that was waiting behind the pill.
  defp load_source_filter(socket, filter) do
    user = socket.assigns.current_user
    page = Posts.feed_page(user, limit: @page_size, filter: filter)

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
    |> stream(:posts, entries, reset: true)
  end

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

  # Periodic reshuffle of the "Who to follow" and "Suggested posts" rails: draw
  # a fresh random slate of not-yet-followed members and posts and reschedule
  # the next tick. Cheap (a ranking query, a follow-edge query and the pooled
  # posts draw, all small), so a 5-minute cadence on an open feed is fine.
  def handle_info(:refresh_suggestions, socket) do
    Process.send_after(self(), :refresh_suggestions, @suggestions_refresh)
    {:noreply, socket |> assign_who_to_follow() |> assign_discover_posts()}
  end

  # The viewer followed / unfollowed a tag elsewhere (a tag page in another tab,
  # issue #872): redraw the "Tags you follow" and "Who to follow" rails so an
  # open feed reflects it live. Posts already streamed stay; the new tag's posts
  # arrive on the next load, like a fresh person-follow.
  def handle_info({:tag_follows_changed, _}, socket) do
    {:noreply, socket |> assign_followed_tags() |> assign_who_to_follow()}
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
    case PostTranslations.apply_ready(socket.assigns.post_translations, translation) do
      :ignore ->
        {:noreply, socket}

      {key, map} ->
        {:noreply, socket |> assign(:post_translations, map) |> restream_translated(key)}
    end
  end

  def handle_info({:translation_failed, key, target}, socket) do
    case PostTranslations.apply_failed(socket.assigns.post_translations, key, target) do
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

      # A post nobody on this tab asked for must not be counted by the pill
      # either: the pill's whole promise is that clicking it shows those posts
      # right here.
      not Posts.feed_filter_accepts?(socket.assigns.feed_filter, entry) ->
        {:noreply, socket}

      Posts.visible_to?(entry.post, user) ->
        {:noreply, update(socket, :pending_posts, &[decorate(entry, user, socket) | &1])}

      true ->
        {:noreply, socket}
    end
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
      <%!-- Two columns on desktop: the feed, plus a "Who to follow" rail that
      uses the otherwise-empty side space. The rail is desktop-only (the grid
      collapses to one column under md, and the rail is hidden anyway). --%>
      <div class="grid gap-6 md:grid-cols-3">
        <%!-- min-w-0: below md the grid is a single implicit `auto` track that
        respects this column's min-content, so a long `truncate` descendant (a
        threaded reply's parent-excerpt) would otherwise force the column — and
        the whole page — wider than a phone viewport. --%>
        <div class="min-w-0 space-y-4 md:col-span-2">
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
          <div
            :if={!@composer_open?}
            class="flex items-center gap-2 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800"
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
          there would be no way back. --%>
          <.post_filter_tabs
            :if={@source_tabs?}
            id="feed-source-tabs"
            active={to_string(@feed_filter)}
            event="filter-source"
            options={feed_filter_options()}
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
          <.post_list :if={!@empty?} id="feed-posts" phx-update="stream" data-post-list>
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
          card drops to the bottom of the page; the "Who to follow" rail stays
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
        the profile-style "Who to follow" card (suggestions the viewer doesn't
        already follow; a live follow, no reload, drops the row and surfaces the
        next) plus the "Other formats" card — the same aside the profile shows.
        Rendered WITH the page on purpose: a lazily loaded rail popped in after
        the paint and read as slowness (the v7.200.3 laziness was undone). --%>
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

          <.card :if={@recommended_users != []} id="who-to-follow">
            <.section_title class="mb-4">{gettext("Who to follow")}</.section_title>
            <ul class="space-y-5">
              <.user_row
                :for={user <- @recommended_users}
                user={user}
                current_user={@current_user}
                current_user_id={@current_user.id}
                work_info_by_id={@work_info_by_id}
                following_by_id={@following_by_id}
                posts={Map.get(@suggested_posts_by_id, user.id, [])}
                live?
              />
            </ul>
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
              <button
                id="discover-reshuffle"
                type="button"
                phx-click="reshuffle-discover"
                title={gettext("Show other posts")}
                aria-label={gettext("Show other posts")}
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
