defmodule VutuvWeb.SettingsController do
  @moduledoc """
  The owner's account settings, split off the old everything-on-one-page edit
  form into focused pages: privacy & visibility, notifications, and an account
  hub (username, emails, data export, security links, delete). The profile
  content itself (photos, name, about) stays on `UserController.edit`.

  Owner-only, enforced exactly like the edit page: `UserResolveSlug` resolves
  the `:slug`, `AuthUser` 403s anyone who is not that member, `EnsureActivated`
  keeps it consistent with the rest of the `/:slug` scope.
  """
  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.UserResolveSlug)
  plug(VutuvWeb.Plug.AuthUser)
  plug(VutuvWeb.Plug.EnsureActivated)
  plug(:scrub_params, "user" when action in [:update_privacy, :update_notifications])

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User

  def index(conn, _params), do: render(conn, "index.html", user: conn.assigns[:user])

  def privacy(conn, _params) do
    user = conn.assigns[:user]
    render(conn, "privacy.html", user: user, changeset: User.changeset(user))
  end

  def update_privacy(conn, %{"user" => params}) do
    user = conn.assigns[:user]

    save(
      conn,
      params,
      "privacy.html",
      ~p"/#{user}/settings/privacy",
      gettext("Privacy settings saved.")
    )
  end

  def notifications(conn, _params) do
    user = conn.assigns[:user]
    render(conn, "notifications.html", user: user, changeset: User.changeset(user))
  end

  def update_notifications(conn, %{"user" => params}) do
    user = conn.assigns[:user]

    save(
      conn,
      params,
      "notifications.html",
      ~p"/#{user}/settings/notifications",
      gettext("Notification settings saved.")
    )
  end

  # The settings sub-forms each submit only their own fields; Accounts.update_user/2
  # casts that subset and leaves the rest of the profile untouched. On success we
  # stay on the same settings page (not the public profile) so the change reads as
  # "saved, here", with the toggle reflecting the new value.
  defp save(conn, params, template, redirect_to, flash) do
    user = conn.assigns[:user]

    case Accounts.update_user(user, params) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, flash)
        |> redirect(to: redirect_to)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(template, user: user, changeset: changeset)
    end
  end
end
