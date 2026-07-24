defmodule VutuvWeb.PostLive.Thread do
  @moduledoc """
  The permalink page's conversation as an embedded LiveView, rendered by
  `VutuvWeb.PostController.render_post/4` via `live_render` (the profile's
  pattern: the controller keeps owning the URL, the agent-format negotiation
  and the page chrome; the socket owns the conversation card).

  It renders `Vutuv.Posts.thread_window/3`: a small conversation whole
  (`:all`, the issue #1006 page unchanged), a big one as a **window around
  the permalinked post** — the root pinned on top, a "Show N earlier posts"
  expander over the nearest ancestors, the post, the first chunk of its own
  reply subtree and a "Show N more replies" expander. The expanders are plain
  `phx-click` events that widen the server-side budgets and re-query; no
  custom JS. Before this, a long thread rendered every post — the 131-post
  test thread came to ~930 KB of HTML and one embedded action-bar LiveView
  **per card** (132 sockets per visitor).

  Inside this host the cards' action bars are the in-process
  `VutuvWeb.PostLive.ActionsComponent` (one process for the whole page). The
  thread subscribes to each *shown* post's counter topic itself and forwards
  `{:post_counters, …}` to the matching component, so the permalink keeps the
  live-ticking counters the per-card `Actions` LiveViews used to provide —
  bounded by the window size instead of the conversation size.

  Mounted off-router (embedded), so it applies the session locale and
  resolves the viewer from the cookie's `session_token` itself via
  `VutuvWeb.Live.InitAssigns.assign_embedded/2`, like the profile.
  """

  use Phoenix.LiveView

  import VutuvWeb.PostComponents,
    only: [post_card: 1, thread_conversation: 1, thread_window_conversation: 1]

  import VutuvWeb.UI, only: [card: 1, delimited_count: 1]

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Posts
  alias Vutuv.Social
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.PostLive.ActionsComponent

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    defaults = Posts.thread_window_defaults()

    socket =
      socket
      |> assign(:post_id, session["post_id"])
      |> assign(:auto_scroll?, session["auto_scroll"] != false)
      |> assign(:ancestor_budget, defaults.ancestors)
      |> assign(:reply_budget, defaults.replies)
      |> assign(:subscribed_ids, MapSet.new())
      |> load_window()

    {:ok, socket}
  end

  @impl true
  def handle_event("thread-earlier", _params, socket) do
    step = Posts.thread_window_defaults().ancestor_page

    {:noreply,
     socket
     |> assign(:ancestor_budget, socket.assigns.ancestor_budget + step)
     |> load_window()}
  end

  def handle_event("thread-more", _params, socket) do
    step = Posts.thread_window_defaults().reply_page

    {:noreply,
     socket
     |> assign(:reply_budget, socket.assigns.reply_budget + step)
     |> load_window()}
  end

  @impl true
  def handle_info({:post_counters, %{post_id: post_id} = payload}, socket) do
    # This host holds the post-topic subscriptions for its cards; the matching
    # in-process bar applies the payload (`ActionBar.apply_counters/2`). The
    # id mirrors post_card's `actions_id` for entry-less thread nodes.
    send_update(ActionsComponent, id: "post-actions-#{post_id}", counters: payload)
    {:noreply, socket}
  end

  def handle_info({:post_deleted, %{post_id: _}}, socket) do
    # A shown post vanished (the author deleted it mid-visit): re-window, so
    # the conversation heals instead of keeping a dead card.
    {:noreply, load_window(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # (Re)computes the window for the current budgets and batches what the
  # cards need: engagement for every shown post's action bar and the viewer's
  # follow edges for the ⋯ menus' mute items — the way the feed does it.
  defp load_window(socket) do
    viewer = socket.assigns.current_user

    case Posts.get_post(socket.assigns.post_id) do
      nil ->
        # Deleted while the socket lived; the controller 404s the next load.
        socket |> assign(:window, nil) |> assign(:focus, nil)

      post ->
        window =
          Posts.thread_window(post, viewer,
            ancestors: socket.assigns.ancestor_budget,
            replies: socket.assigns.reply_budget
          )

        posts = window_posts(window)
        ids = Enum.map(posts, & &1.id)

        follows =
          if viewer do
            posts
            |> Enum.map(& &1.user_id)
            |> Enum.uniq()
            |> Enum.reject(&(&1 == viewer.id))
            |> then(&Social.follow_edges(viewer.id, &1))
          else
            %{}
          end

        socket
        |> assign(:window, window)
        |> assign(:focus, Enum.find(posts, &(&1.id == post.id)) || post)
        |> assign(:engagement, Posts.post_engagement_map(ids, viewer))
        |> assign(:viewer_follows, follows)
        |> subscribe_shown(ids)
    end
  end

  defp window_posts(%{mode: :all, posts: posts}), do: posts

  defp window_posts(%{mode: :window} = window) do
    List.wrap(window.root) ++ window.chain ++ window.subtree
  end

  # One counter subscription per shown card, added as expanders reveal more —
  # bounded by the window, never the conversation.
  defp subscribe_shown(socket, ids) do
    if connected?(socket) do
      subscribed = socket.assigns.subscribed_ids
      fresh = ids |> MapSet.new() |> MapSet.difference(subscribed)
      Enum.each(fresh, &Posts.subscribe_post/1)
      assign(socket, :subscribed_ids, MapSet.union(subscribed, fresh))
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="post-thread-frame">
      <%= cond do %>
        <% is_nil(@window) -> %>
          <div id="post-thread-gone"></div>
        <% @window.mode == :all and @window.total == 1 -> %>
          <%!-- No conversation: the post stands alone as its own card. The
          author's Edit/Delete live in the card's own ⋯ menu. --%>
          <.post_card
            post={@focus}
            viewer={@current_user}
            viewer_follow={@viewer_follows[@focus.user_id]}
            engagement={@engagement[@focus.id]}
            mode={:full}
            conn_or_socket={@socket}
          />
        <% true -> %>
          <%!-- The conversation (issue #1006), rendered like a feed thread
          row: connector lines between the cards, the permalinked post the
          tinted full-mode card; with context above it, app.js scrolls it into
          view on arrival ([data-thread-scroll]). A big conversation opens as
          a window around the post and grows over the expanders. --%>
          <.card id="post-thread">
            <%= if @window.mode == :all do %>
              <.thread_conversation
                posts={@window.posts}
                focus_id={@focus.id}
                viewer={@current_user}
                viewer_follows={@viewer_follows}
                engagement={@engagement}
                auto_scroll?={@auto_scroll?}
                conn_or_socket={@socket}
              />
            <% else %>
              <.thread_window_conversation
                window={@window}
                focus_id={@focus.id}
                viewer={@current_user}
                viewer_follows={@viewer_follows}
                engagement={@engagement}
                auto_scroll?={@auto_scroll?}
                conn_or_socket={@socket}
              />
            <% end %>
          </.card>
          <p
            :if={@window.mode == :window and @window.rest > 0 and @window.root}
            class="mt-3 px-2 text-sm text-slate-600 dark:text-slate-400"
          >
            {gettext("This post is part of a conversation with %{formatted} posts.",
              formatted: delimited_count(@window.total)
            )}<span :if={@window.truncated?}>+</span>
            <.link
              href={Posts.path(@window.root)}
              class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
              id="thread-from-start"
            >
              {gettext("Read it from the start")}
            </.link>
          </p>
      <% end %>
    </div>
    """
  end
end
