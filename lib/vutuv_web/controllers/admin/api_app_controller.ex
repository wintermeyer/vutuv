defmodule VutuvWeb.Admin.ApiAppController do
  @moduledoc """
  The operator's view of every registered OAuth application, with the
  bad-player kill switch: suspending an app makes all of its tokens fail
  on their very next request (`Vutuv.ApiAuth.verify_token/1` checks
  `suspended_at` live); unsuspending restores them.
  """

  use VutuvWeb, :controller

  alias Vutuv.ApiAuth
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    render(conn, "index.html", apps: ApiAuth.list_all_apps())
  end

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
