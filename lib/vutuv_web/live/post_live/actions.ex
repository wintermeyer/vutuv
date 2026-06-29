defmodule VutuvWeb.PostLive.Actions do
  @moduledoc """
  The per-card action bar (like / reply / repost / bookmark with live counters)
  as a **standalone LiveView**, embedded via `live_render` from
  `VutuvWeb.PostComponents.post_card/1` on the **dead controller pages** that
  have no LiveView host — the post permalink, the author archive, the profile
  served as a controller page. There the bar is the only live part, so it keeps
  its own post-topic subscription and its counters tick in real time.

  On LiveView host pages the bar is instead the in-process
  `VutuvWeb.PostLive.ActionsComponent`; both render the same markup
  (`VutuvWeb.PostComponents.post_actions/1`) and share the same toggle rule
  (`VutuvWeb.PostLive.ActionBar`).

  It re-renders on `{:post_counters, …}` (absolute counts, idempotent).
  Logged-out viewers get the same live counters; pressing a button sends them
  to the login page. Mounted outside the `live_session` (embedded), so it
  applies the session locale itself, like `VutuvWeb.ShellLive`.
  """
  use Phoenix.LiveView

  import VutuvWeb.PostComponents, only: [post_actions: 1]

  alias Vutuv.Posts
  alias VutuvWeb.PostLive.ActionBar

  @impl true
  def mount(_params, session, socket) do
    post_id = session["post_id"]
    viewer_id = session["user_id"]
    VutuvWeb.LiveLocale.put_locale(session)

    # The post topic carries everything this bar needs: absolute counts for
    # every viewer, plus — when the actor is the viewer (`:by_user_id`) — the
    # cue to re-sync the viewer's own filled-in flags across their tabs.
    if connected?(socket), do: Posts.subscribe_post(post_id)

    # A list page that already loaded the post can hand the engagement in via
    # the session, sparing this bar its own query on mount; otherwise (a lone
    # card on a dead page) the bar loads it itself.
    engagement = ActionBar.engagement_or_load(session["engagement"], post_id, viewer_id)

    {:ok,
     socket
     |> assign(:id, session["id"])
     |> assign(:post_id, post_id)
     |> assign(:viewer_id, viewer_id)
     |> assign(:engagement, engagement)}
  end

  @impl true
  def handle_event("toggle", %{"kind" => kind}, socket) when kind in ~w(like bookmark repost) do
    {:noreply, ActionBar.toggle(kind, socket)}
  end

  @impl true
  def handle_info(
        {:post_counters,
         %{likes: likes, bookmarks: bookmarks, reposts: reposts, replies: replies} = payload},
        socket
      ) do
    case socket.assigns.engagement do
      nil ->
        {:noreply, socket}

      engagement ->
        # The viewer's own toggle (from this or another of their tabs) carries
        # `:by_user_id`: reload so their filled-in flags follow, not just the
        # counts. Anything else — another viewer's toggle, a reply-count tick —
        # is counts-only and never touches this viewer's flags.
        if payload[:by_user_id] && payload[:by_user_id] == socket.assigns.viewer_id do
          {:noreply, ActionBar.load_engagement(socket)}
        else
          {:noreply,
           assign(socket, :engagement, %{
             engagement
             | likes: likes,
               bookmarks: bookmarks,
               reposts: reposts,
               replies: replies
           })}
        end
    end
  end

  # The post was deleted while the bar was open: re-checking engagement turns it
  # nil and the bar empties (the dead permalink/profile pages can only react
  # through this bar).
  def handle_info({:post_deleted, %{post_id: post_id}}, socket) do
    if post_id == socket.assigns.post_id do
      {:noreply, ActionBar.load_engagement(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.post_actions id={@id} post_id={@post_id} engagement={@engagement} />
    """
  end
end
