defmodule VutuvWeb.UsernameController do
  use VutuvWeb, :controller

  # Changing the username is owner-only.
  plug(VutuvWeb.Plug.AuthUser)
  plug(:scrub_params, "user" when action in [:create])

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Mentions

  def new(conn, _params) do
    user = conn.assigns[:user]
    render_new(conn, user, User.username_changeset(user))
  end

  def create(conn, %{"user" => params}) do
    user = conn.assigns[:current_user]
    # The old handle is gone after the rename, so count the posts it appears in
    # now to report how many were updated.
    affected = Mentions.count_post_mentions(user.username)

    case Accounts.update_username(user, params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, rename_success_message(user.username, affected))
        |> redirect(to: ~p"/#{user}")

      {:error, changeset} ->
        # The rename did not persist, so `user.username` still holds the old
        # handle and `affected` already counted its mentions: reuse it.
        conn
        |> put_status(:unprocessable_entity)
        |> render_new(user, changeset, affected)
    end
  end

  defp rename_success_message(handle, 0),
    do: gettext("Your username is now @%{handle}.", handle: handle)

  defp rename_success_message(handle, affected) do
    gettext("Your username is now @%{handle}.", handle: handle) <>
      " " <>
      ngettext(
        "We updated %{formatted} post that mentioned your old handle and notified its author.",
        "We updated %{formatted} posts that mentioned your old handle and notified their authors.",
        affected,
        formatted: VutuvWeb.UI.compact_count(affected)
      )
  end

  defp render_new(conn, user, changeset),
    do: render_new(conn, user, changeset, Mentions.count_post_mentions(user.username))

  defp render_new(conn, user, changeset, mention_count) do
    render(conn, "new.html",
      changeset: changeset,
      quota: Accounts.username_change_quota(user),
      mention_count: mention_count
    )
  end

  # Backs the live "is this name free?" check in the change form.
  def availability(conn, params) do
    value = params["value"] |> to_string() |> String.trim() |> String.downcase()
    json(conn, availability_payload(value))
  end

  defp availability_payload(value) do
    # `username_changeset/2` now also rejects a handle already used in a post
    # (the anti-hijack rule). Check "already taken" first so a claimed handle
    # reads "taken" rather than "used in a post"; both can be true at once.
    changeset = User.username_changeset(%User{}, %{"username" => value})

    cond do
      Accounts.username_taken?(value) ->
        %{available: false, message: gettext("@%{handle} is already taken.", handle: value)}

      not changeset.valid? ->
        %{
          available: false,
          message: VutuvWeb.ErrorHelpers.translate_error(changeset.errors[:username])
        }

      true ->
        %{available: true, message: gettext("@%{handle} is available.", handle: value)}
    end
  end
end
