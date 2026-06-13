defmodule VutuvWeb.PostLive.Saved do
  @moduledoc """
  The private "my likes" / "my bookmarks" pages (`/likes`, `/bookmarks`):
  one LiveView, two live actions, tab links patching between them. Lists
  the posts the current user liked or bookmarked, newest engagement first,
  visibility-filtered at read time, with the feed's cursor "Load more".

  Un-liking / un-bookmarking — from the card's action bar here, or from any
  other session — removes the card live: the actor's own activity topic
  carries `{:engagement_changed, …}` for exactly this (likewise a new like
  in another tab prepends here).
  """

  use VutuvWeb, :live_view

  import VutuvWeb.PostComponents

  alias Vutuv.Posts

  @page_size 20

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Vutuv.Activity.subscribe(socket.assigns.current_user.id)
    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    page = load_page(socket, nil)
    if connected?(socket), do: subscribe_posts(page.entries)

    {:noreply,
     socket
     |> assign(:page_title, title(socket.assigns.live_action))
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> stream(:posts, page.entries, reset: true)}
  end

  # Unlike the feed (which hears about deletions on the viewer's own topic, as a
  # follower of the author), a liker/bookmarker usually does not follow the
  # author, so the only signal that reaches is each shown post's topic.
  defp subscribe_posts(entries), do: Enum.each(entries, &Posts.subscribe_post(&1.id))

  defp load_page(socket, cursor) do
    user = socket.assigns.current_user
    opts = [limit: @page_size, cursor: cursor]

    case socket.assigns.live_action do
      :likes -> Posts.liked_posts_page(user, opts)
      :bookmarks -> Posts.bookmarked_posts_page(user, opts)
    end
  end

  defp title(:likes), do: gettext("Likes")
  defp title(:bookmarks), do: gettext("Bookmarks")

  @impl true
  def handle_event("load-more", _params, socket) do
    page = load_page(socket, socket.assigns.cursor)
    subscribe_posts(page.entries)

    {:noreply,
     socket
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> stream(:posts, page.entries, at: -1)}
  end

  @impl true
  def handle_info(
        {:engagement_changed, %{kind: kind, post_id: post_id, active?: active?}},
        socket
      ) do
    if kind == tab_kind(socket.assigns.live_action) do
      {:noreply, apply_change(socket, post_id, active?)}
    else
      {:noreply, socket}
    end
  end

  # A shown post was deleted (by its author or via account teardown): drop the
  # card instead of leaving a ghost whose action bar has emptied itself.
  def handle_info({:post_deleted, %{post_id: post_id}}, socket) do
    {:noreply, stream_delete_by_dom_id(socket, :posts, "posts-#{post_id}")}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp tab_kind(:likes), do: :like
  defp tab_kind(:bookmarks), do: :bookmark

  defp apply_change(socket, post_id, false) do
    stream_delete_by_dom_id(socket, :posts, "posts-#{post_id}")
  end

  defp apply_change(socket, post_id, true) do
    case Posts.get_post(post_id) do
      nil ->
        socket

      post ->
        Posts.subscribe_post(post.id)
        stream_insert(socket, :posts, post, at: 0)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="saved" class="py-6">
      <div class="mx-auto max-w-2xl space-y-4">
        <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">
          {title(@live_action)}
        </h1>

        <nav class="flex gap-1 text-sm font-semibold" aria-label={gettext("Saved posts")}>
          <.tab patch={~p"/likes"} active?={@live_action == :likes} id="tab-likes">
            {gettext("Likes")}
          </.tab>
          <.tab patch={~p"/bookmarks"} active?={@live_action == :bookmarks} id="tab-bookmarks">
            {gettext("Bookmarks")}
          </.tab>
        </nav>

        <div id="saved-posts" phx-update="stream" class="space-y-4">
          <p class="hidden text-slate-600 dark:text-slate-400 only:block" id="saved-empty">
            {empty_text(@live_action)}
          </p>
          <div :for={{dom_id, post} <- @streams.posts} id={dom_id}>
            <.post_card post={post} viewer={@current_user} mode={:preview} conn_or_socket={@socket} />
          </div>
        </div>

        <.load_more :if={@more?} />
      </div>
    </div>
    """
  end

  defp empty_text(:likes), do: gettext("Nothing here yet. Posts you like show up here.")
  defp empty_text(:bookmarks), do: gettext("Nothing here yet. Posts you bookmark show up here.")

  attr(:patch, :string, required: true)
  attr(:active?, :boolean, required: true)
  attr(:id, :string, required: true)
  slot(:inner_block, required: true)

  defp tab(assigns) do
    ~H"""
    <.link
      patch={@patch}
      id={@id}
      aria-current={@active? && "page"}
      class={[
        "rounded-lg px-3 py-1.5",
        @active? && "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100",
        !@active? &&
          "text-slate-500 hover:bg-slate-100 dark:text-slate-400 dark:hover:bg-slate-800"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
