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
  # The "Who to follow" rail reuses the profile's compact user row.
  import VutuvWeb.UserHTML, only: [user_row: 1]

  alias Vutuv.Posts
  alias Vutuv.Social
  alias VutuvWeb.UserHelpers

  @page_size 20

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    if connected?(socket), do: Vutuv.Activity.subscribe(user.id)

    page = Posts.feed_page(user, limit: @page_size)

    {:ok,
     socket
     |> assign(:page_title, gettext("Feed"))
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> assign(:empty?, page.entries == [])
     |> assign(:pending_posts, [])
     # The composer starts collapsed to a single "What's new?" button; posting
     # (own activity arriving below) collapses it again.
     |> assign(:composer_open?, false)
     |> assign_who_to_follow()
     |> stream_configure(:posts, dom_id: &"feed-#{&1.id}")
     |> stream(:posts, with_engagement(page.entries, user))}
  end

  # The desktop "Who to follow" rail: the most-followed members the viewer does
  # not already follow (nor themselves), capped to a short list. Excluding the
  # current follows keeps it a suggestion box — every row's button reads
  # "Follow", and following one (live, no reload) drops it so the next rises.
  defp assign_who_to_follow(socket) do
    user = socket.assigns.current_user

    candidates =
      Social.most_followed_users(12)
      |> Enum.reject(&(&1.id == user.id))

    already = UserHelpers.following_map(user, candidates)

    suggestions =
      candidates
      |> Enum.reject(&Map.has_key?(already, &1.id))
      |> Enum.take(5)

    socket
    |> assign(:recommended_users, suggestions)
    |> assign(:work_info_by_id, UserHelpers.work_information_map(suggestions, 60))
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

  # The rail's "Follow" buttons (user_row live?): follow with no reload, then
  # refresh the suggestions so the followed member drops off and the next rises.
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

  def handle_info(_other, socket), do: {:noreply, socket}

  # Own activity (this or another session) appears immediately; other
  # people's waits behind the pill — and only when the post is visible.
  defp insert_entry(socket, entry, actor_id) do
    user = socket.assigns.current_user
    # Attach the viewer's follow edge so the card's mute toggle works on a
    # live-arrived post too (nil for an own post — no self-follow).
    entry =
      entry && Map.put(entry, :viewer_follow, Social.follow_edge(user.id, entry.post.user_id))

    cond do
      is_nil(entry) ->
        {:noreply, socket}

      actor_id == user.id ->
        {:noreply,
         socket
         |> assign(:empty?, false)
         # The viewer just posted (this or another session): collapse the composer.
         |> assign(:composer_open?, false)
         |> stream_insert(:posts, entry, at: 0)}

      # Mirror the pull path's blocked-author filter: a third party's repost
      # must not carry a blocked author's post into the feed (blocking already
      # severed the direct follow). visible_to?/2 alone never checks blocks.
      Social.blocked_between?(user.id, entry.post.user_id) ->
        {:noreply, socket}

      Posts.visible_to?(entry.post, user) ->
        {:noreply, update(socket, :pending_posts, &[entry | &1])}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="feed" class="py-6">
      <%!-- Two columns on desktop: the feed, plus a "Who to follow" rail that
      uses the otherwise-empty side space. The rail is desktop-only (the grid
      collapses to one column under md, and the rail is hidden anyway). --%>
      <div class="grid gap-6 md:grid-cols-3">
        <div class="space-y-4 md:col-span-2">
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

          <div id="feed-posts" phx-update="stream" class="space-y-4">
            <div :for={{dom_id, entry} <- @streams.posts} id={dom_id}>
              <.post_card
                post={entry.post}
                viewer={@current_user}
                viewer_follow={entry[:viewer_follow]}
                mode={:preview}
                reposted_by={entry.reposted_by}
                entry_id={entry.id}
                conn_or_socket={@socket}
                engagement={entry.engagement}
              />
            </div>
          </div>

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
        </div>

        <%!-- Desktop-only "Who to follow" rail (hidden under md, where the grid
        is one column anyway). The follow buttons are live (no reload). --%>
        <aside id="who-to-follow" class="hidden md:block">
          <.card :if={@recommended_users != []}>
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
            <.card_footer_link href={~p"/listings/most_followed_users"}>
              {gettext("Show all")}
            </.card_footer_link>
          </.card>
        </aside>
      </div>
    </div>
    """
  end
end
