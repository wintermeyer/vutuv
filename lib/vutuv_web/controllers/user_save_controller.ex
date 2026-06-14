defmodule VutuvWeb.UserSaveController do
  @moduledoc """
  The profile-header "bookmark / like this member" toggles: a private, silent
  save with no follow or connection prerequisite (see `Vutuv.Social`). Each is
  a CSRF POST to save and DELETE to remove (the `:id` on a remove is the target
  member's id, scoped to the current user), and both land back on the referrer
  or the actor's own profile. Logged-in only.
  """
  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Social

  plug(VutuvWeb.Plug.RequireLoginOr404)
  plug(:scrub_params, "user_bookmark" when action == :bookmark)
  plug(:scrub_params, "user_like" when action == :like)

  def bookmark(conn, %{"user_bookmark" => %{"target_user_id" => target_id}}) do
    save(conn, target_id, &Social.bookmark_user/2, gettext("Bookmarked."))
  end

  def unbookmark(conn, %{"id" => target_id}) do
    unsave(conn, target_id, &Social.unbookmark_user/2, gettext("Bookmark removed."))
  end

  def like(conn, %{"user_like" => %{"target_user_id" => target_id}}) do
    save(conn, target_id, &Social.like_user/2, gettext("Liked."))
  end

  def unlike(conn, %{"id" => target_id}) do
    unsave(conn, target_id, &Social.unlike_user/2, gettext("Like removed."))
  end

  # The actor is always the session user, never trusted from params, so a
  # request cannot forge a save on someone else's behalf. A save across a block
  # or of yourself is refused by the context with an opaque error. Both legs
  # land back on the target's profile, where the toggle lives.
  defp save(conn, target_id, fun, ok_msg) do
    with %User{} = target <- fetch_target(target_id),
         :ok <- fun.(conn.assigns.current_user, target) do
      conn |> put_flash(:info, ok_msg) |> redirect(to: ~p"/#{target}")
    else
      _ ->
        conn
        |> put_flash(:error, gettext("Something went wrong"))
        |> redirect(to: ~p"/")
    end
  end

  defp unsave(conn, target_id, fun, ok_msg) do
    case fetch_target(target_id) do
      %User{} = target ->
        :ok = fun.(conn.assigns.current_user, target)
        conn |> put_flash(:info, ok_msg) |> redirect(to: ~p"/#{target}")

      nil ->
        redirect(conn, to: ~p"/")
    end
  end

  # A garbage id is a no-op (nil), not a 500.
  defp fetch_target(target_id) do
    case Vutuv.UUIDv7.cast_or_nil(target_id) do
      nil -> nil
      id -> Repo.get(User, id)
    end
  end
end
