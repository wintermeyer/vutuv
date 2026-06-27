defmodule VutuvWeb.Admin.ApiAppController do
  @moduledoc """
  The suspend / unsuspend kill switch behind the OAuth-application list. The list
  itself is a LiveView (`VutuvWeb.Admin.ApiAppLive`), where the toggles act
  reload-free; these CSRF POSTs are the no-JS / scriptable fallback. Suspending an
  app makes all of its tokens fail on their very next request
  (`Vutuv.ApiAuth.verify_token/1` checks `suspended_at` live); unsuspending
  restores them.
  """

  use VutuvWeb, :controller

  alias Vutuv.ApiAuth
  alias VutuvWeb.ControllerHelpers

  def suspend(conn, %{"id" => id}) do
    case ApiAuth.get_any_app(id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      app ->
        ApiAuth.suspend_app!(app)

        conn
        |> put_flash(
          :info,
          gettext("\"%{name}\" is suspended; its tokens are refused.", name: app.name)
        )
        |> redirect(to: ~p"/admin/api_apps")
    end
  end

  def unsuspend(conn, %{"id" => id}) do
    case ApiAuth.get_any_app(id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      app ->
        ApiAuth.unsuspend_app!(app)

        conn
        |> put_flash(:info, gettext("\"%{name}\" is active again.", name: app.name))
        |> redirect(to: ~p"/admin/api_apps")
    end
  end
end
