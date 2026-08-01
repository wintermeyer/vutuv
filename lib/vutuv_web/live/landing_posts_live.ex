defmodule VutuvWeb.LandingPostsLive do
  @moduledoc """
  The carousel of real posts on the logged-out landing page.

  Embedded via `live_render` in `page/index.html.heex`: the sign-up page is
  otherwise a dead controller page, and the counters under these posts are the
  one thing on it that has to keep moving.

  **One socket for the whole carousel, not one per card.** The action bars are
  in-process `PostLive.ActionsComponent`s, because this LiveView is their host —
  on a dead page each bar would instead be its own embedded `PostLive.Actions`
  LiveView, and ten of those (five posts, rendered twice for the marquee loop) on
  the page every crawler meets is not a price worth paying. The counters stay
  live all the same: this module holds the one post-topic subscription per post
  and forwards each `{:post_counters, …}` to the matching bars with
  `send_update`, exactly as `PostLive.Thread` does for a conversation. The bars
  keep their own engagement behind an `assign_new`, so forwarding is the only
  thing that moves them — writing a new engagement into this module's assigns
  updates the state and nothing on the screen.

  Nobody here can act — a logged-out visitor pressing a heart is sent to the
  login page by `PostLive.ActionBar` — so the bars are read in practice. That is
  the point: how a post was received is part of what the block is showing.

  The disconnected mount renders the cached posts from
  `Vutuv.Landing.showcase_posts/0`, so crawlers and JS-less readers get them as
  plain HTML with their counts as of that moment; the sliding is pure CSS
  (`.post-carousel` in `components.css`) and needs no JavaScript either.
  """
  use Phoenix.LiveView

  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.PostComponents, only: [post_card: 1]

  alias Vutuv.Landing
  alias Vutuv.Posts
  alias VutuvWeb.PostLive.ActionsComponent

  @impl true
  def mount(_params, session, socket) do
    # Embedded outside the live_session, so re-apply the request locale the way
    # ShellLive does.
    VutuvWeb.LiveLocale.put_locale(session)

    posts = Landing.showcase_posts()
    ids = Enum.map(posts, & &1.id)

    # One subscription per post, taken out here rather than per bar: the bars are
    # LiveComponents and share this process, so a subscription each would be the
    # same messages delivered several times over.
    if connected?(socket), do: Enum.each(ids, &Posts.subscribe_post/1)

    # One batched query for every card's counts, so ten cards cost one round trip
    # instead of ten. Always anonymous: this page is only ever served logged out,
    # so there are no per-viewer filled-in hearts to resolve.
    {:ok,
     socket |> assign(:posts, posts) |> assign(:engagement, Posts.post_engagement_map(ids, nil))}
  end

  @impl true
  def handle_info({:post_counters, %{post_id: post_id} = payload}, socket) do
    # Forwarded, not assigned. `ActionsComponent` keeps its engagement behind an
    # `assign_new` on purpose — so a host re-render cannot undo a viewer's
    # just-clicked toggle — which means writing a fresh engagement into this
    # LiveView's own assigns changes the state and nothing on the screen (it did
    # exactly that here until the render was checked rather than the assign).
    # `send_update` with `:counters` is the door the component leaves open, the
    # same one `PostLive.Thread` uses.
    #
    # Both copies: the marquee renders every post twice and the ids carry the
    # copy prefix, so a single send_update would leave one of the two halves
    # showing the old number as it slid past.
    for copy <- ~w(a b) do
      send_update(ActionsComponent, id: "post-actions-#{copy}-#{post_id}", counters: payload)
    end

    {:noreply, socket}
  end

  # A post deleted while somebody is looking at the page: drop the card rather
  # than leave a dead one turning past.
  def handle_info({:post_deleted, %{post_id: post_id}}, socket) do
    {:noreply, assign(socket, :posts, Enum.reject(socket.assigns.posts, &(&1.id == post_id)))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # One card per post, in the carousel's fixed-width, equal-height frame. The
  # duplicate half passes `aria-hidden` / `inert` straight through.
  attr(:posts, :list, required: true)
  attr(:socket, :any, required: true)
  attr(:engagement, :map, required: true)

  attr(:copy, :string,
    required: true,
    doc:
      "prefix for this half's element ids. The marquee renders every post twice, " <>
        "and `post_card` derives its body / menu / time ids from the post — so " <>
        "without a prefix the page would carry every id twice, which is invalid " <>
        "HTML and breaks the PostPreviewClamp hook, since that keys on them"
  )

  attr(:rest, :global)

  defp carousel_cards(assigns) do
    ~H"""
    <div class="contents" {@rest}>
      <%!-- max_lines: the reader's own clamp preference is right in a timeline,
            where posts are read one after another, and wrong in a carousel,
            where the installation default (15 lines on vutuv.de) made one card
            tower over the rest. Six lines makes every card a teaser. --%>
      <.post_card
        :for={post <- @posts}
        post={post}
        viewer={nil}
        mode={:preview}
        max_lines={6}
        entry_id={"#{@copy}-#{post.id}"}
        engagement={@engagement[post.id]}
        conn_or_socket={@socket}
        class="post-carousel__card"
      />
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="landing-posts">
      <%!-- Rendered twice so the marquee loops seamlessly (see .post-carousel in
            components.css). The second half is aria-hidden AND inert: hidden
            alone would leave its links in the tab order, so a keyboard reader
            would tab into content a screen reader was told is not there. --%>
      <div class="post-carousel mt-6">
        <div class="post-carousel__track">
          <.carousel_cards posts={@posts} socket={@socket} engagement={@engagement} copy="a" />
          <.carousel_cards posts={@posts} socket={@socket} engagement={@engagement} copy="b" aria-hidden="true" inert />
        </div>
      </div>

    </div>
    """
  end
end
