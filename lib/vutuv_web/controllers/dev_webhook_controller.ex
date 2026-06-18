defmodule VutuvWeb.DevWebhookController do
  @moduledoc """
  Webhook subscriptions on the developer's app page: add (the signing
  secret is shown once, like every credential), delete, send a test ping,
  re-enable after an auto-disable. Owner-scoped through the app lookup.
  """

  use VutuvWeb, :controller

  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.App
  alias Vutuv.Webhooks
  alias Vutuv.Webhooks.Subscription

  import VutuvWeb.ControllerHelpers, only: [with_app: 3]

  plug(VutuvWeb.Plug.RequireLoginOr404)

  def new(conn, %{"app_id" => app_id}) do
    with_app(conn, app_id, fn conn, app ->
      render(conn, "new.html", app: app, changeset: Webhooks.change_subscription(%Subscription{}))
    end)
  end

  def create(conn, %{"app_id" => app_id, "subscription" => params}) do
    with_app(conn, app_id, fn conn, app ->
      case Webhooks.create_subscription(app, params) do
        {:ok, _subscription, secret} ->
          conn
          |> put_flash(:new_webhook_secret, secret)
          |> redirect(to: ~p"/developers/apps/#{app.id}")

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render("new.html", app: app, changeset: changeset)
      end
    end)
  end

  def delete(conn, %{"app_id" => app_id, "id" => id}) do
    with_subscription(conn, app_id, id, fn conn, app, subscription ->
      Webhooks.delete_subscription!(subscription)

      conn
      |> put_flash(:info, gettext("The webhook was deleted."))
      |> redirect(to: ~p"/developers/apps/#{app.id}")
    end)
  end

  def ping(conn, %{"app_id" => app_id, "id" => id}) do
    with_subscription(conn, app_id, id, fn conn, app, subscription ->
      Webhooks.ping(subscription)

      conn
      |> put_flash(:info, gettext("A ping event is on its way to your endpoint."))
      |> redirect(to: ~p"/developers/apps/#{app.id}")
    end)
  end

  def reactivate(conn, %{"app_id" => app_id, "id" => id}) do
    with_subscription(conn, app_id, id, fn conn, app, subscription ->
      Webhooks.reactivate!(subscription)

      conn
      |> put_flash(:info, gettext("The webhook is active again."))
      |> redirect(to: ~p"/developers/apps/#{app.id}")
    end)
  end

  defp with_subscription(conn, app_id, id, fun) do
    with %App{} = app <- ApiAuth.get_app(conn.assigns.current_user, app_id),
         %Subscription{} = subscription <- Webhooks.get_subscription(app, id) do
      fun.(conn, app, subscription)
    else
      nil -> VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end
end
