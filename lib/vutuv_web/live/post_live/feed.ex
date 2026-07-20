defmodule VutuvWeb.PostLive.Feed do
  @moduledoc """
  The newsfeed: the composer on top, then the viewer's timeline — own posts
  plus posts *and reposts* of followed authors (visibility-filtered pull
  model, `Vutuv.Posts.feed_page/2`), cursor "Load more" at the bottom — the
  same pagination style as notifications. Entries are
  `%{id:, post:, reposted_by:, at:}` maps; repost entries render the
  "Reposted by X" line on the card.

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

  alias Vutuv.Posts
  alias Vutuv.Social
  alias VutuvWeb.Live.DayClockRestream
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.UserHelpers

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
    if connected?(socket) do
      Vutuv.Activity.subscribe(user.id)
      # Refresh the Berlin-day-relative post stamps ("09:50 Uhr" -> "Gestern,
      # 09:50 Uhr") the moment the German day rolls over at midnight.
      Vutuv.DayClock.subscribe()
      # Reshuffle the "Who to follow" rail every few minutes while the page stays
      # open, so a long-lived session keeps seeing fresh suggestions even without
      # a reload (a new visit reshuffles too, via this same mount).
      Process.send_after(self(), :refresh_suggestions, @suggestions_refresh)
    end

    page = Posts.feed_page(user, limit: @page_size)
    entries = with_engagement(page.entries, user)

    socket
    |> assign(:page_title, gettext("Feed"))
    |> assign(:more?, page.more?)
    |> assign(:cursor, page.next_cursor)
    |> assign(:empty?, page.entries == [])
    |> assign(:pending_posts, [])
    # The composer starts collapsed to a single "What's new?" button; posting
    # (own activity arriving below) collapses it again.
    |> assign(:composer_open?, false)
    # The set of entries currently on screen, kept so the midnight :day_changed
    # tick can re-render each stamp in place (streams don't retain their data).
    # Order/dupes don't matter: the refresh uses stream_insert update_only, which
    # updates existing rows where they sit and ignores ones already gone.
    |> assign(:entries, entries)
    |> assign_followed_tags()
    |> assign_who_to_follow()
    |> assign_discover_posts()
    |> stream_configure(:posts, dom_id: &"feed-#{&1.id}")
    |> stream(:posts, entries)
  end

  # The desktop "Tags you follow" rail (issue #872): the member's tag
  # subscriptions as chips, each with a reload-free ✕ unfollow. Refreshed
  # whenever the follow set changes (an unfollow here, or a follow/unfollow made
  # on a tag page while this feed is open — see the :tag_follows_changed handler).
  defp assign_followed_tags(socket) do
    assign(socket, :followed_tags, Vutuv.Tags.followed_tags(socket.assigns.current_user))
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
  defp assign_who_to_follow(socket) do
    user = socket.assigns.current_user
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

    socket
    |> assign(:recommended_users, users)
    |> assign(:work_info_by_id, UserHelpers.work_information_map(users, 60))
    # Every suggestion is by construction someone the viewer does not follow, so
    # the follow buttons all render the "Follow" state from an empty map.
    |> assign(:following_by_id, %{})
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
  defp with_engagement(entries, user) do
    ancestor_ids = fn entry -> Enum.map(entry[:ancestors] || [], & &1.id) end

    engagement =
      entries
      |> Enum.flat_map(fn entry -> [entry.post.id | ancestor_ids.(entry)] end)
      |> Enum.uniq()
      |> Posts.post_engagement_map(user)

    follows =
      entries
      |> Enum.map(& &1.post.user_id)
      |> Enum.uniq()
      |> then(&Social.follow_edges(user.id, &1))

    Enum.map(entries, fn entry ->
      entry
      |> Map.put(:engagement, engagement[entry.post.id])
      |> Map.put(:ancestor_engagement, Map.take(engagement, ancestor_ids.(entry)))
      |> Map.put(:viewer_follow, follows[entry.post.user_id])
    end)
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    page =
      Posts.feed_page(socket.assigns.current_user,
        limit: @page_size,
        cursor: socket.assigns.cursor
      )

    # A post shown higher up (as a newer repost, or nested in a shown thread)
    # must not reappear on an older page: `feed_page/2` dedups within a page but
    # can't see the ones already on screen. The higher card already carries the
    # complete follow-scoped roster, so dropping the older duplicate loses
    # nothing. Filter before the engagement batch so it queries only survivors.
    shown = shown_post_ids(socket.assigns.entries)
    fresh = Enum.reject(page.entries, &MapSet.member?(shown, &1.post.id))
    entries = with_engagement(fresh, socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> update(:entries, &(&1 ++ entries))
     |> stream(:posts, entries, at: -1)}
  end

  def handle_event("open-composer", _params, socket) do
    {:noreply, assign(socket, :composer_open?, true)}
  end

  # The composer's corner ✕ (feed compose only) bubbles up here to collapse it.
  def handle_event("close-composer", _params, socket) do
    {:noreply, assign(socket, :composer_open?, false)}
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

      shown = Enum.find(socket.assigns.entries, &(&1.post.id == post_id)) ->
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

  def handle_info(_other, socket), do: {:noreply, socket}

  # Swap in the post's now-screenshot-carrying copy and re-stream the entry in
  # place (update_only, so an off-page id is a harmless no-op). The entry's other
  # fields — engagement, follow edge, repost roster — are preserved.
  defp refresh_shown_post(socket, post_id) do
    with entry when not is_nil(entry) <-
           Enum.find(socket.assigns.entries, &(&1.post.id == post_id)),
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
      actor_id == user.id ->
        decorated = decorate(entry, user)

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

      Posts.visible_to?(entry.post, user) ->
        {:noreply, update(socket, :pending_posts, &[decorate(entry, user) | &1])}

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
  defp decorate(entry, user) do
    entry
    |> Map.put(:viewer_follow, Social.follow_edge(user.id, entry.post.user_id))
    |> Map.put(:engagement, Posts.post_engagement(entry.post.id, user.id))
  end

  # Every post id currently represented on screen — each streamed entry's own
  # post plus every ancestor it nests — so a live or paged repost of an
  # already-shown post updates that card (or drops) instead of duplicating it.
  defp shown_post_ids(entries) do
    for entry <- entries,
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
          <.composer_trigger>), revealed via phx-click. The composer stays
          mounted (just hidden) so a half-typed draft survives a background
          feed re-render; posting or the composer's corner ✕ collapses it. --%>
          <.composer_trigger
            :if={!@composer_open?}
            viewer={@current_user}
            id="open-composer"
            phx-click="open-composer"
          >
            {gettext("Write a post")}
          </.composer_trigger>

          <%!-- The panel is just the composer component; its corner ✕ bubbles a
          `close-composer` up to this LiveView, and it also collapses on its own
          after the viewer posts (see the {:new_post, …} handler). --%>
          <div id="composer-panel" class={[!@composer_open? && "hidden"]}>
            <.live_component
              module={VutuvWeb.PostLive.Composer}
              id="composer"
              current_user={@current_user}
              post={nil}
            />
          </div>

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
            <div :for={{dom_id, entry} <- @streams.posts} id={dom_id} class={post_row_class()}>
              <.post_thread_entry
                post={entry.post}
                viewer={@current_user}
                viewer_follow={entry[:viewer_follow]}
                ancestors={entry[:ancestors]}
                ancestor_engagement={entry[:ancestor_engagement] || %{}}
                reposted_by={entry.reposted_by}
                reposters={entry[:reposters]}
                entry_id={entry.id}
                conn_or_socket={@socket}
                engagement={entry.engagement}
                surface={:flat}
              />
            </div>
          </.post_list>

          <p :if={@empty? && @pending_posts == []} class="text-slate-600 dark:text-slate-400">
            {gettext("Nothing here yet. Follow people to fill your feed, or write your first post.")}
            <.link
              navigate={~p"/listings/most_followed_users"}
              class="font-semibold text-brand-600 hover:text-brand-700"
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
        next) plus the "Other formats" card — the same aside the profile shows. --%>
        <aside class="hidden space-y-6 md:block">
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
            <ul class="space-y-4">
              <.user_row
                :for={user <- @recommended_users}
                user={user}
                current_user={@current_user}
                current_user_id={@current_user.id}
                work_info_by_id={@work_info_by_id}
                following_by_id={@following_by_id}
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
                  href={~p"/#{post.user}/posts/#{post.id}"}
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
