defmodule VutuvWeb.BlockController do
  @moduledoc """
  Blocking flows: the profile-footer Block control (create), the private
  blocked list at /blocks (index), and unblocking (delete — the lookup is
  scoped to the current user, so nobody can lift someone else's block).
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Social

  plug(VutuvWeb.Plug.RequireLoginOr404)

  def index(conn, _params) do
    render(conn, "index.html", blocks: Social.list_blocked(conn.assigns.current_user))
  end

  def create(conn, %{"block" => %{"user_id" => user_id}}) do
    with %User{} = target <- Vutuv.Repo.get(User, user_id),
         {:ok, _block} <- Social.block_user(conn.assigns.current_user, target) do
      conn
      |> put_flash(
        :info,
        gettext("You blocked @%{slug}. You can undo this on your blocked list.",
          slug: target.active_slug
        )
      )
      |> redirect(to: ~p"/#{target}")
    else
      _ ->
        conn
        |> put_flash(:error, gettext("Something went wrong"))
        |> redirect(to: ~p"/")
    end
  end

  def delete(conn, %{"id" => id}) do
    block = Social.get_block!(conn.assigns.current_user, id)
    target = Vutuv.Repo.get(User, block.blocked_id)
    :ok = Social.unblock_user(conn.assigns.current_user, target)

    conn
    |> put_flash(:info, gettext("You unblocked @%{slug}.", slug: target.active_slug))
    |> redirect(to: ~p"/blocks")
  end
end
