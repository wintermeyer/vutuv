defmodule VutuvWeb.BlockController do
  @moduledoc """
  Blocking flows: the profile-footer Block control and the "Block someone by
  @handle" form on /blocks (both `create`), the private blocked list at /blocks
  (index), and unblocking (delete — the lookup is scoped to the current user, so
  nobody can lift someone else's block).
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Social

  plug(VutuvWeb.Plug.RequireLoginOr404)

  def index(conn, _params) do
    render(conn, "index.html", blocks: Social.list_blocked(conn.assigns.current_user))
  end

  # The profile-footer control posts a user_id and lands back on the profile.
  def create(conn, %{"block" => %{"user_id" => user_id}}) do
    with %User{} = target <- VutuvWeb.ControllerHelpers.get_user(user_id),
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

  # The "Block someone" form on /blocks: block by @handle so a member can act
  # without first finding the person's profile (the "block my ex" case). Lands
  # back on the blocked list, where the new entry now shows. The leading "@" is
  # optional and the handle is matched case-insensitively (active_slug is
  # always lower-case).
  def create(conn, %{"block" => %{"handle" => handle}}) do
    current_user = conn.assigns.current_user
    cleaned = handle |> String.trim() |> String.trim_leading("@")
    target = cleaned != "" && Accounts.get_user_by_slug(String.downcase(cleaned))

    cond do
      not match?(%User{}, target) ->
        conn
        |> put_flash(:error, handle_lookup_error(cleaned))
        |> redirect(to: ~p"/blocks")

      target.id == current_user.id ->
        conn
        |> put_flash(:error, gettext("You cannot block yourself."))
        |> redirect(to: ~p"/blocks")

      true ->
        # block_user/2 is idempotent; check first only to word the notice.
        already_blocked? = Social.get_block(current_user.id, target.id) != nil
        {:ok, _block} = Social.block_user(current_user, target)

        conn
        |> put_flash(:info, block_notice(already_blocked?, target.active_slug))
        |> redirect(to: ~p"/blocks")
    end
  end

  defp handle_lookup_error(""),
    do: gettext("Enter a member's @handle to block them.")

  defp handle_lookup_error(handle),
    do: gettext("We could not find a member with the handle @%{handle}.", handle: handle)

  defp block_notice(true, slug),
    do: gettext("You already blocked @%{slug}.", slug: slug)

  defp block_notice(false, slug),
    do: gettext("You blocked @%{slug}.", slug: slug)

  def delete(conn, %{"id" => id}) do
    block = Social.get_block!(conn.assigns.current_user, id)
    target = Vutuv.Repo.get(User, block.blocked_id)
    :ok = Social.unblock_user(conn.assigns.current_user, target)

    conn
    |> put_flash(:info, gettext("You unblocked @%{slug}.", slug: target.active_slug))
    |> redirect(to: ~p"/blocks")
  end
end
