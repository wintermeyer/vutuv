defmodule VutuvWeb.PostLive.Feed do
  @moduledoc """
  The newsfeed: the composer on top, then own + followed authors' posts
  (visibility-filtered pull model, `Vutuv.Posts.feed_page/2`), cursor "Load
  more" at the bottom — the same pagination style as notifications.

  Real-time: `Vutuv.Posts.create_post/2` broadcasts `{:new_post, …}` to the
  author and every follower over `Vutuv.Activity`. The author's own posts
  prepend immediately; everyone else's accumulate behind a *"Show N new
  posts"* pill (auto-inserting posts under a reading user is hostile), each
  checked against `visible_to?/2` server-side before it is even counted —
  the pill must not leak denied posts.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.PostComponents

  alias Vutuv.Posts

  @page_size 20

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns[:current_user] do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You must be logged in to access that page"))
         |> redirect(to: ~p"/login")}

      user ->
        if connected?(socket), do: Vutuv.Activity.subscribe(user.id)

        page = Posts.feed_page(user, limit: @page_size)

        {:ok,
         socket
         |> assign(:page_title, gettext("Feed"))
         |> assign(:more?, page.more?)
         |> assign(:cursor, page.next_cursor)
         |> assign(:empty?, page.entries == [])
         |> assign(:pending_posts, [])
         |> stream(:posts, page.entries)}
    end
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
      |> Enum.reduce(socket, fn post, socket ->
        stream_insert(socket, :posts, post, at: 0)
      end)
      |> assign(:pending_posts, [])
      |> assign(:empty?, false)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:new_post, %{post_id: post_id, author_id: author_id}}, socket) do
    user = socket.assigns.current_user
    post = Posts.get_post(post_id)

    cond do
      is_nil(post) ->
        {:noreply, socket}

      author_id == user.id ->
        # Own posts (this or another session) appear immediately.
        {:noreply,
         socket
         |> assign(:empty?, false)
         |> stream_insert(:posts, post, at: 0)}

      Posts.visible_to?(post, user) ->
        {:noreply, update(socket, :pending_posts, &[post | &1])}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="feed" class="py-6">
      <div class="mx-auto max-w-2xl space-y-4">
        <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">{gettext("Feed")}</h1>

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
          <div :for={{dom_id, post} <- @streams.posts} id={dom_id}>
            <.post_card post={post} viewer={@current_user} mode={:preview} />
          </div>
        </div>

        <p :if={@empty? && @pending_posts == []} class="text-slate-400">
          {gettext("Nothing here yet. Follow people to fill your feed, or write your first post.")}
        </p>

        <div :if={@more?} class="text-center">
          <.button id="load-more" variant="secondary" phx-click="load-more" phx-disable-with="…">
            {gettext("Load more")}
          </.button>
        </div>
      </div>
    </div>
    """
  end
end
