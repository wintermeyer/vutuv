defmodule VutuvWeb.DevAppController do
  @moduledoc """
  The developer's app registry at `/developers/apps`: register an OAuth
  application (self-service, owned by the member's account), see its
  client id, rotate the secret (shown once, like the access tokens),
  edit the redirect URIs, delete. See `Vutuv.ApiAuth` and the docs at
  `/developers/authentication`.
  """

  use VutuvWeb, :controller

  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.App

  plug(VutuvWeb.Plug.RequireLoginOr404)

  def index(conn, _params) do
    render(conn, "index.html", apps: ApiAuth.list_apps(conn.assigns.current_user))
  end

  def new(conn, _params) do
    render(conn, "new.html", changeset: ApiAuth.change_app(%App{}))
  end

  def create(conn, %{"app" => params}) do
    case ApiAuth.create_app(conn.assigns.current_user, normalize(params)) do
      {:ok, app, secret} ->
        conn
        |> put_flash(:new_app_secret, secret)
        |> redirect(to: ~p"/developers/apps/#{app.id}")

      {:error, changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    with_app(conn, id, fn conn, app ->
      render(conn, "show.html", app: app, webhooks: Vutuv.Webhooks.list_subscriptions(app))
    end)
  end

  def edit(conn, %{"id" => id}) do
    with_app(conn, id, fn conn, app ->
      render(conn, "edit.html", app: app, changeset: ApiAuth.change_app(app))
    end)
  end

  def update(conn, %{"id" => id, "app" => params}) do
    with_app(conn, id, fn conn, app ->
      case ApiAuth.update_app(app, normalize(params)) do
        {:ok, app} ->
          conn
          |> put_flash(:info, gettext("Application updated."))
          |> redirect(to: ~p"/developers/apps/#{app.id}")

        {:error, changeset} ->
          render(conn, "edit.html", app: app, changeset: changeset)
      end
    end)
  end

  def regenerate_secret(conn, %{"id" => id}) do
    with_app(conn, id, fn conn, app ->
      {app, secret} = ApiAuth.regenerate_secret!(app)

      conn
      |> put_flash(:new_app_secret, secret)
      |> put_flash(:info, gettext("The old client secret stopped working."))
      |> redirect(to: ~p"/developers/apps/#{app.id}")
    end)
  end

  # The form posts the redirect URIs as a one-per-line textarea.
  defp normalize(params) do
    case Map.pop(params, "redirect_uris_text") do
      {nil, params} -> params
      {text, params} -> Map.put(params, "redirect_uris", String.split(text, ~r/\R/, trim: true))
    end
  end

  def delete(conn, %{"id" => id}) do
    with_app(conn, id, fn conn, app ->
      ApiAuth.delete_app!(app)

      conn
      |> put_flash(:info, gettext("The application and all its access were deleted."))
      |> redirect(to: ~p"/developers/apps")
    end)
  end

  # Owner-scoped lookup with the uniform 404 (same shape as the sibling
  # DevWebhookController.with_app/3).
  defp with_app(conn, id, fun) do
    case ApiAuth.get_app(conn.assigns.current_user, id) do
      %App{} = app -> fun.(conn, app)
      nil -> VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end
end
