defmodule VutuvWeb.SlugController do
  use VutuvWeb, :controller

  # Changing the username is owner-only.
  plug(VutuvWeb.Plug.AuthUser)
  plug(:scrub_params, "user" when action in [:create])

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User

  def new(conn, _params) do
    user = conn.assigns[:user]
    render_new(conn, user, User.slug_changeset(user))
  end

  def create(conn, %{"user" => params}) do
    user = conn.assigns[:current_user]

    case Accounts.update_active_slug(user, params) do
      {:ok, user} ->
        conn
        |> put_flash(
          :info,
          gettext("Your username is now @%{handle}.", handle: user.active_slug)
        )
        |> redirect(to: ~p"/#{user}")

      {:error, changeset} ->
        render_new(conn, user, changeset)
    end
  end

  defp render_new(conn, user, changeset) do
    render(conn, "new.html", changeset: changeset, quota: Accounts.slug_change_quota(user))
  end

  # Backs the live "is this name free?" check in the change form.
  def availability(conn, params) do
    value = params["value"] |> to_string() |> String.trim() |> String.downcase()
    json(conn, availability_payload(value))
  end

  defp availability_payload(value) do
    changeset = User.slug_changeset(%User{}, %{"active_slug" => value})

    cond do
      not changeset.valid? ->
        %{
          available: false,
          message: VutuvWeb.ErrorHelpers.translate_error(changeset.errors[:active_slug])
        }

      Accounts.slug_taken?(value) ->
        %{available: false, message: gettext("@%{handle} is already taken.", handle: value)}

      true ->
        %{available: true, message: gettext("@%{handle} is available.", handle: value)}
    end
  end
end
