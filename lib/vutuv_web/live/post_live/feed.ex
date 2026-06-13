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

  alias Vutuv.Posts

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
     |> stream_configure(:posts, dom_id: &"feed-#{&1.id}")
     |> stream(:posts, page.entries)}
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
     |> stream(:posts, page.entries, at: -1)}
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
    entry = post && %{id: "post-#{post.id}", post: post, reposted_by: nil, at: post.inserted_at}
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
          at: NaiveDateTime.utc_now(:second)
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

    cond do
      is_nil(entry) ->
        {:noreply, socket}

      actor_id == user.id ->
        {:noreply,
         socket
         |> assign(:empty?, false)
         |> stream_insert(:posts, entry, at: 0)}

      # Mirror the pull path's blocked-author filter: a third party's repost
      # must not carry a blocked author's post into the feed (blocking already
      # severed the direct follow). visible_to?/2 alone never checks blocks.
      Vutuv.Social.blocked_between?(user.id, entry.post.user_id) ->
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
      <div class="mx-auto max-w-2xl space-y-4">
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

        <.live_component
          module={VutuvWeb.PostLive.Composer}
          id="composer"
          current_user={@current_user}
          post={nil}
        />

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
              mode={:preview}
              reposted_by={entry.reposted_by}
              entry_id={entry.id}
              conn_or_socket={@socket}
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
    </div>
    """
  end
end
