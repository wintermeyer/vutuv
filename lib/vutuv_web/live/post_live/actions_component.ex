defmodule VutuvWeb.PostLive.ActionsComponent do
  @moduledoc """
  The per-card action bar (like / reply / repost / bookmark) as an **in-process
  LiveComponent**, rendered by `VutuvWeb.PostComponents.post_card/1` on every
  LiveView host page (the feed, /likes, /bookmarks, the reply page, the profile
  Posts section).

  It replaces the per-card nested `live_render` that each card used to embed —
  one extra LiveView process plus one `"post:<id>"` PubSub subscription apiece,
  which morphdom re-mounted (a visible flash) every time the host re-rendered a
  stream. As a component it runs in the host's process, owns the viewer's own
  toggle, and re-renders only itself in place: no extra process, no per-card
  subscription, no flash.

  It deliberately does **not** subscribe to the post topic, so other people's
  counts refresh on reload / "Load more" rather than ticking live — the
  "minimum PubSub" trade-off. Dead controller pages, which have no LiveView
  host, keep the standalone `VutuvWeb.PostLive.Actions` LiveView, which does
  still tick live. One host opts back in: the permalink thread
  (`VutuvWeb.PostLive.Thread`) subscribes to its few dozen shown posts itself
  and forwards each `{:post_counters, …}` here via `send_update` (the
  `:counters` clause below), so the post's own page keeps live counters at one
  process for the whole conversation.
  """
  use VutuvWeb, :live_component

  import VutuvWeb.PostComponents, only: [post_actions: 1]

  alias VutuvWeb.PostLive.ActionBar

  @impl true
  def update(%{counters: payload}, socket) do
    # A live counter tick forwarded by a host that holds the post-topic
    # subscriptions for its cards (the permalink thread): counts-only, unless
    # the toggle was the viewer's own from another tab (see
    # `ActionBar.apply_counters/2`).
    {:ok, ActionBar.apply_counters(socket, payload)}
  end

  def update(assigns, socket) do
    # `assign_new` loads engagement once, then keeps our own (possibly toggled)
    # copy across later host re-renders — the list-based profile/reply hosts
    # re-render the whole card list, and re-applying the host's stale preload
    # would undo the viewer's just-clicked toggle. The first pass uses what the
    # host batched (feed/saved) or, when none is handed in (profile/reply), its
    # own query — matching the old self-loading child bar.
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:post_id, assigns.post_id)
     |> assign(:viewer_id, assigns.viewer_id)
     |> assign_new(:engagement, fn ->
       ActionBar.engagement_or_load(assigns[:engagement], assigns.post_id, assigns.viewer_id)
     end)}
  end

  @impl true
  def handle_event("toggle", %{"kind" => kind}, socket) when kind in ~w(like bookmark repost) do
    {:noreply, ActionBar.toggle(kind, socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.post_actions
        id={@id}
        post_id={@post_id}
        engagement={@engagement}
        viewer_id={@viewer_id}
        target={@myself}
      />
    </div>
    """
  end
end
