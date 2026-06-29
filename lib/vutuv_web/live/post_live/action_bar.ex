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

    if user && post do
      # Errors (:not_visible, :restricted) mean the button should not have been
      # live — the reload below shows the truth either way.
      _ =
        case {kind, engagement} do
          {"like", %{liked?: true}} -> Posts.unlike_post(user, post)
          {"like", _} -> Posts.like_post(user, post)
          {"bookmark", %{bookmarked?: true}} -> Posts.unbookmark_post(user, post)
          {"bookmark", _} -> Posts.bookmark_post(user, post)
          {"repost", %{reposted?: true}} -> Posts.unrepost_post(user, post)
          {"repost", _} -> Posts.repost_post(user, post)
        end
    end

    # The viewer's own filled-in flags are not in any broadcast, so reload them.
    load_engagement(socket)
  end

  @doc """
  Reloads the viewer's engagement for the post and assigns it (turns `nil` once
  the post is deleted, which empties the bar).
  """
  def load_engagement(socket) do
    assign(
      socket,
      :engagement,
      Posts.post_engagement(socket.assigns.post_id, socket.assigns.viewer_id)
    )
  end
end
