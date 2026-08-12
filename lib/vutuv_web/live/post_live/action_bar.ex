defmodule VutuvWeb.PostLive.ActionBar do
  @moduledoc """
  The like / bookmark / repost toggle rule behind both renderings of a post
  card's action bar: the in-process `VutuvWeb.PostLive.ActionsComponent` on the
  LiveView host pages (feed, /likes, /bookmarks, reply, profile) and the
  standalone `VutuvWeb.PostLive.Actions` LiveView on the dead controller pages.

  Both keep the same `post_id` / `viewer_id` / `engagement` socket assigns, so
  one copy of the rule serves both: a logged-out viewer is sent to the login
  page, a vanished post is a no-op, otherwise the toggle is written and the
  viewer's own filled-in flags are reloaded.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  alias Vutuv.Accounts.User
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo

  @doc """
  The engagement a freshly mounted bar starts from: what the host batched and
  handed in, or — when none was (a lone card on a dead page, the profile/reply
  parent) — its own query. The single source of the "handed-in or load" rule
  for both the component's `update/2` and the standalone bar's `mount/3`.
  """
  def engagement_or_load(handed_in, post_id, viewer_id) do
    handed_in || Posts.post_engagement(post_id, viewer_id)
  end

  @doc """
  Handles a `"like"` / `"bookmark"` / `"repost"` toggle, returning the updated
  socket (works for both a LiveComponent and a LiveView socket).
  """
  def toggle(kind, socket) when kind in ~w(like bookmark repost) do
    case {socket.assigns.viewer_id, socket.assigns.engagement} do
      {nil, _} -> redirect(socket, to: ~p"/login")
      {_, nil} -> socket
      {viewer_id, engagement} -> do_toggle(kind, viewer_id, engagement, socket)
    end
  end

  defp do_toggle(kind, viewer_id, engagement, socket) do
    user = Repo.get(User, viewer_id)
    post = Repo.get(Post, socket.assigns.post_id)
    page = acting_page(socket)

    if user && post do
      # Errors (:not_visible, :restricted, :not_allowed) mean the button should
      # not have been live — the reload below shows the truth either way.
      _ = act(kind, engagement, page || user, user, post)
    end

    # The viewer's own filled-in flags are not in any broadcast, so reload them.
    load_engagement(socket)
  end

  # Undoing needs only the actor; doing it needs the acting member too, so the
  # page's act can record who pressed the button (issue #1336). `actor` is the
  # page when one is being spoken as, otherwise the member themselves.
  defp act("like", %{liked?: true}, actor, _by, post), do: Posts.unlike_post(actor, post)

  defp act("bookmark", %{bookmarked?: true}, actor, _by, post),
    do: Posts.unbookmark_post(actor, post)

  defp act("repost", %{reposted?: true}, actor, _by, post), do: Posts.unrepost_post(actor, post)

  defp act("like", _, %Organization{} = page, by, post), do: Posts.like_post(page, by, post)
  defp act("like", _, actor, _by, post), do: Posts.like_post(actor, post)

  defp act("bookmark", _, %Organization{} = page, by, post),
    do: Posts.bookmark_post(page, by, post)

  defp act("bookmark", _, actor, _by, post), do: Posts.bookmark_post(actor, post)

  defp act("repost", _, %Organization{} = page, by, post), do: Posts.repost_post(page, by, post)
  defp act("repost", _, actor, _by, post), do: Posts.repost_post(actor, post)

  # Re-read rather than trusted: the assign arrives from the host's own
  # re-authorized `:acting_as`, but the row is what the act is written against,
  # and `Posts` asks the role again before letting it through.
  defp acting_page(socket) do
    case socket.assigns[:acting_as_id] do
      nil -> nil
      id -> Repo.get(Organization, id)
    end
  end

  @doc """
  Applies a `{:post_counters, …}` payload to the bar's socket: counts-only for
  someone else's toggle or a reply-count tick, a full flag reload when the
  toggle was the viewer's own from another tab (`:by_user_id`). Shared by the
  standalone bar's own subscription (`VutuvWeb.PostLive.Actions`) and the
  permalink thread host, which holds the subscriptions for its cards and
  forwards each payload to the matching in-process component via
  `send_update` (`VutuvWeb.PostLive.Thread`).
  """
  def apply_counters(
        socket,
        %{likes: _, bookmarks: _, reposts: _, replies: _} = payload
      ) do
    case socket.assigns.engagement do
      nil ->
        socket

      engagement ->
        if payload[:by_user_id] && payload[:by_user_id] == socket.assigns.viewer_id do
          load_engagement(socket)
        else
          assign(socket, :engagement, apply_counters_to(engagement, payload))
        end
    end
  end

  # The same rule for an engagement rather than a socket. Kept a named function
  # rather than inlined, because the interesting half of this list is easy to
  # forget: **issues #1068 and #1069**, a reaction or a reply from another
  # network arrives without any viewer of ours acting, so this is the only path
  # that updates the remote figures. Since the card shows one number per act
  # (`Posts.shown_counts/1`), leaving them out means a heart from Mastodon simply
  # never moves the heart on the card. The chips ride along, the panel behind
  # them naming the accounts.
  defp apply_counters_to(engagement, payload) do
    %{
      engagement
      | likes: payload.likes,
        bookmarks: payload.bookmarks,
        reposts: payload.reposts,
        replies: payload.replies,
        fediverse_likes: payload.fediverse_likes,
        fediverse_reposts: payload.fediverse_reposts,
        fediverse_reaction_actors: payload.fediverse_reaction_actors,
        fediverse_replies: payload.fediverse_replies
    }
  end

  @doc """
  Reloads the viewer's engagement for the post and assigns it (turns `nil` once
  the post is deleted, which empties the bar).
  """
  def load_engagement(socket) do
    assign(
      socket,
      :engagement,
      Posts.post_engagement(
        socket.assigns.post_id,
        socket.assigns[:acting_as_id] || socket.assigns.viewer_id
      )
    )
  end
end
