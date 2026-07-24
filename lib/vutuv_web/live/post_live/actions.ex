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

  The viewer is authenticated from the cookie's `session_token` (through the
  shared `VutuvWeb.Live.InitAssigns.session_user/1` resolver), never a bare
  `user_id`, so a remotely logged-out device or a suspended member can no longer
  write a like / bookmark / repost from this bar. That lookup runs **only on
  connect**: the throwaway dead render does no writes and its engagement flags
  are the threaded ones the controller already computed for the authenticated
  request, so deferring the resolution keeps a many-post permalink from paying a
  session lookup per card on a render that is discarded the moment the socket
  connects.
  """
  use Phoenix.LiveView

  import VutuvWeb.PostComponents, only: [post_actions: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Posts
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.PostLive.ActionBar

  @impl true
  def mount(_params, session, socket) do
    post_id = session["post_id"]
    VutuvWeb.LiveLocale.put_locale(session)

    # Resolve the viewer from the session token on the connected socket only —
    # it is the one that subscribes and writes. The dead render stays anonymous
    # (viewer_id nil) and renders from the threaded engagement.
    viewer_id = if connected?(socket), do: session_viewer_id(session), else: nil

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

  # The token-resolved viewer id, or nil when the cookie's session token is
  # missing / revoked / belongs to a suspended member.
  defp session_viewer_id(session) do
    case InitAssigns.session_user(session) do
      %User{id: id} -> id
      _ -> nil
    end
  end

  @impl true
  def handle_event("toggle", %{"kind" => kind}, socket) when kind in ~w(like bookmark repost) do
    {:noreply, ActionBar.toggle(kind, socket)}
  end

  @impl true
  def handle_info(
        {:post_counters, %{likes: _, bookmarks: _, reposts: _, replies: _} = payload},
        socket
      ) do
    # The viewer's own toggle (from another of their tabs) carries
    # `:by_user_id` and reloads their filled-in flags too; anything else is
    # counts-only. The rule lives in `ActionBar.apply_counters/2`, shared with
    # the permalink thread host's forwarding.
    {:noreply, ActionBar.apply_counters(socket, payload)}
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
    <.post_actions id={@id} post_id={@post_id} engagement={@engagement} viewer_id={@viewer_id} />
    """
  end
end
