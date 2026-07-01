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
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.UserHelpers

  @page_size 20
  # "Who to follow" rail: how many suggestions to show, the size of the popular
  # pool we shuffle them out of, and how often an open feed reshuffles. Defined
  # here (not beside `assign_who_to_follow`) so `mount_feed/3` above reads a real
  # value — a module attribute is `nil` until the line that sets it.
  @who_to_follow 6
  @suggestion_pool 60
  @suggestions_refresh :timer.minutes(5)

  @impl true
  # Rendered by VutuvWeb.NewsfeedController via `live_render` (off-router, so it
  # can negotiate the agent-format siblings), exactly like UserProfileLive. An
  # off-router LiveView can't use `InitAssigns` as an `on_mount` — that hook
  # attaches a `:handle_params` hook, which it rejects — so mount mirrors it:
  # load the viewer + locale from the session the controller passes, and gate on
  # login here instead of the `:require_login` stage.
  def mount(_params, session, socket) do
    user = InitAssigns.load_user(session["user_id"])
    VutuvWeb.LiveLocale.put_locale(user, session)

    if user do
      {:ok, mount_feed(socket, user, session)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You must be logged in to access that page"))
       |> redirect(to: ~p"/login")}
    end
  end

  defp mount_feed(socket, user, session) do
    if connected?(socket) do
      Vutuv.Activity.subscribe(user.id)
      # Reshuffle the "Who to follow" rail every few minutes while the page stays
      # open, so a long-lived session keeps seeing fresh suggestions even without
      # a reload (a new visit reshuffles too, via this same mount).
      Process.send_after(self(), :refresh_suggestions, @suggestions_refresh)
    end

    page = Posts.feed_page(user, limit: @page_size)

    socket
    |> assign(:current_user, user)
    |> assign(:current_user_id, user.id)
    # The shared app layout reads @shell_path (so ShellLive can zero the page's
    # badge) and @locale (the rail's "Other formats" ?lang= suffix) off the
    # socket; the controller hands both through the session.
    |> assign(:shell_path, session["request_path"])
    |> assign(:page_title, gettext("Feed"))
    |> assign(:locale, session["locale"])
    |> assign(:more?, page.more?)
    |> assign(:cursor, page.next_cursor)
    |> assign(:empty?, page.entries == [])
    |> assign(:pending_posts, [])
    # The composer starts collapsed to a single "What's new?" button; posting
    # (own activity arriving below) collapses it again.
    |> assign(:composer_open?, false)
    |> assign_who_to_follow()
    |> stream_configure(:posts, dom_id: &"feed-#{&1.id}")
    |> stream(:posts, with_engagement(page.entries, user))
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

    candidates =
      Social.most_followed_users(@suggestion_pool)
      |> Enum.reject(&(&1.id == user.id))

    following = UserHelpers.following_map(user, candidates)

    users =
      candidates
      |> Enum.reject(&Map.has_key?(following, &1.id))
      |> Enum.shuffle()
      |> Enum.take(@who_to_follow)

    socket
    |> assign(:recommended_users, users)
    |> assign(:work_info_by_id, UserHelpers.work_information_map(users, 60))
    # Every suggestion is by construction someone the viewer does not follow, so
    # the follow buttons all render the "Follow" state from an empty map.
    |> assign(:following_by_id, %{})
  end

  # Pre-load the action-bar engagement AND the viewer's follow edge to each
  # author for the whole page in one query each, and hang them on each entry, so
  # the per-card Actions LiveViews don't each run their own query (was one query
  # per post) and the card's mute toggle knows its follow id + state without a
  # per-row lookup. Live-arriving single posts carry `engagement: nil` (falls
  # back to the bar's own query) and get their follow edge in `insert_entry/3`.
  defp with_engagement(entries, user) do
    engagement = Posts.post_engagement_map(Enum.map(entries, & &1.post.id), user)

    follows =
      entries
      |> Enum.map(& &1.post.user_id)
      |> Enum.uniq()
      |> then(&Social.follow_edges(user.id, &1))

    Enum.map(entries, fn entry ->
      entry
      |> Map.put(:engagement, engagement[entry.post.id])
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

    {:noreply,
     socket
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> stream(:posts, with_engagement(page.entries, socket.assigns.current_user), at: -1)}
  end

  def handle_event("open-composer", _params, socket) do
    {:noreply, assign(socket, :composer_open?, true)}
  end

  def handle_event("close-composer", _params, socket) do
    {:noreply, assign(socket, :composer_open?, false)}
  end

  # The rail's "Follow" button (user_row live?): follow with no reload, then
  # recompute the rail so the new followee drops out (we only suggest members
  # the viewer doesn't already follow) and the next candidate fills the slot.
  def handle_event("follow", %{"followee" => followee_id}, socket) do
    me = socket.assigns.current_user

    if me && me.id != followee_id, do: Social.follow(me, followee_id)

    {:noreply, assign_who_to_follow(socket)}
  end

  def handle_event("show-new", _params, socket) do
    socket =
      socket.assigns.pending_posts
      # Oldest pending first, so the newest ends up on top.
      |> Enum.reverse()
      |> Enum.reduce(socket, fn entry, socket ->
        stream_insert(socket, :posts, entry, at: 0)
      end)
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
          at: post.inserted_at,
          engagement: nil
        }

    insert_entry(socket, entry, author_id)
  end

  def handle_info(
        {:new_repost, %{repost_id: repost_id, post_id: post_id, reposter_id: reposter_id}},
        socket
      ) do
    post = Posts.get_post(post_id)
    reposter = Vutuv.Repo.get(Vutuv.Accounts.User, reposter_id)

    entry =
      post && reposter &&
        %{
          id: "repost-#{repost_id}",
          post: post,
          reposted_by: reposter,
          at: NaiveDateTime.utc_now(:second),
          engagement: nil
        }

    insert_entry(socket, entry, reposter_id)
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

  # Periodic reshuffle of the "Who to follow" rail: draw a fresh random slate of
  # not-yet-followed members and reschedule the next tick. Cheap (one ranking
  # query + one follow-edge query, both already small), so a 5-minute cadence on
  # an open feed is fine.
  def handle_info(:refresh_suggestions, socket) do
    Process.send_after(self(), :refresh_suggestions, @suggestions_refresh)
    {:noreply, assign_who_to_follow(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # Own activity (this or another session) appears immediately; other
  # people's waits behind the pill — and only when the post is visible.
  defp insert_entry(socket, nil, _actor_id), do: {:noreply, socket}

  defp insert_entry(socket, entry, actor_id) do
    user = socket.assigns.current_user

    cond do
      actor_id == user.id ->
        {:noreply,
         socket
         |> assign(:empty?, false)
         # The viewer just posted (this or another session): collapse the composer.
         |> assign(:composer_open?, false)
         |> stream_insert(:posts, decorate(entry, user), at: 0)}

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

  # Attach the viewer's follow edge (so the card's mute toggle works on a
  # live-arrived post too — nil for an own post, no self-follow) and the
  # action-bar engagement, both queried in this process. The bar component
  # renders straight from the entry's engagement, so a live-arrived card never
  # queries during render (which would race the sandbox in tests). Only the
  # two branches that keep the entry pay for it — a blocked or denied post is
  # dropped before either query runs.
  defp decorate(entry, user) do
    entry
    |> Map.put(:viewer_follow, Social.follow_edge(user.id, entry.post.user_id))
    |> Map.put(:engagement, Posts.post_engagement(entry.post.id, user.id))
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
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">{gettext("Feed")}</h1>
            <p class="text-sm font-semibold">
              <.link navigate={~p"/likes"} class="text-brand-600 hover:text-brand-700">
                {gettext("Likes")}
              </.link>
              <span class="text-slate-300 dark:text-slate-600">·</span>
              <.link navigate={~p"/bookmarks"} class="text-brand-600 hover:text-brand-700">
                {gettext("Bookmarks")}
              </.link>
            </p>
          </div>

          <%!-- Collapsed by default: the same dashed compose tile as the
          profile's Beiträge section (<.empty_add>), reused as a reveal trigger
          so the compose affordance reads identically across the app. The
          composer stays mounted (just hidden) so a half-typed draft survives a
          background feed re-render; posting or Cancel collapses it again. --%>
          <.empty_add :if={!@composer_open?} id="open-composer" phx-click="open-composer">
            {gettext("Write a post")}
          </.empty_add>

          <div id="composer-panel" class={[!@composer_open? && "hidden"]}>
            <.live_component
              module={VutuvWeb.PostLive.Composer}
              id="composer"
              current_user={@current_user}
              post={nil}
            />
            <div class="mt-1 text-right">
              <button
                type="button"
                phx-click="close-composer"
                class="text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
              >
                {gettext("Cancel")}
              </button>
            </div>
          </div>

          <div :if={@pending_posts != []} class="text-center">
            <.button id="show-new-posts" variant="secondary" phx-click="show-new">
              {ngettext("Show %{count} new post", "Show %{count} new posts", length(@pending_posts),
                count: length(@pending_posts)
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
                reposted_by={entry.reposted_by}
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
          <.other_formats_card base_path="/feed" locale={@locale} id="feed-other-formats" />
        </aside>
      </div>
    </div>
    """
  end
end
