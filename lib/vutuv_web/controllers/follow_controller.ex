defmodule VutuvWeb.FollowController do
  use VutuvWeb, :controller

  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.RequireLoginOr404)
  plug(:scrub_params, "follow" when action in [:create])

  def create(conn, %{"follow" => follow_params}) do
    # The follower is always the session user, never trusted from params, so a
    # request cannot forge a follow edge on someone else's behalf. All follow
    # paths go through Social.follow/2, which also pushes the live
    # "started following you" notification to the followee (passing the loaded
    # struct saves it a Repo.get).
    case Vutuv.Social.follow(conn.assigns.current_user, follow_params["followee_id"]) do
      {:ok, _follow} ->
        conn
        |> put_flash(:info, gettext("You are now following this person."))
        |> redirect(to: referrer_url(conn))

      {:error, _changeset} ->
        conn
        |> put_flash(:error, gettext("Something went wrong"))
        |> redirect(to: referrer_url(conn))
    end
  end

  def delete(conn, %{"id" => id}) do
    # Social.unfollow!/2 scopes the lookup to the current user, so a caller can
    # only delete their own follow edges, never an arbitrary follow by id.
    Vutuv.Social.unfollow!(conn.assigns.current_user_id, id)

    conn
    |> put_flash(:info, gettext("You are no longer following this person."))
    |> redirect(to: referrer_url(conn))
  end

  def toggle_mute(conn, %{"id" => id}) do
    # Scoped to the session user like unfollow!/2: you can only mute a follow
    # you own. Muting is silent — the followee is never notified; only their
    # posts leave the muter's feed, while the follow (and any vernetzt status)
    # stays put.
    follow = Vutuv.Social.toggle_follow_mute!(conn.assigns.current_user_id, id)

    message =
      if follow.muted do
        gettext("Muted. Their posts no longer appear in your feed.")
      else
        gettext("Unmuted. Their posts appear in your feed again.")
      end

    conn
    |> put_flash(:info, message)
    |> redirect(to: referrer_url(conn))
  end

  # Fall back to the logged-in user's profile. This controller never assigns
  # :user, so the old `conn.assigns[:user]` fallback was always nil and raised
  # when interpolated into the route on a refererless request.
  defp referrer_url(conn) do
    ControllerHelpers.referrer_or_profile(conn, conn.assigns[:current_user])
  end
end
