defmodule VutuvWeb.ConnectedAppController do
  @moduledoc """
  The member's side of OAuth: which applications may act for them
  (`/connected_apps`), with the granted permissions spelled out and a
  one-click revoke that kills the app's tokens immediately.
  """

  use VutuvWeb, :controller

  alias Vutuv.ApiAuth

  plug(VutuvWeb.Plug.RequireLoginOr404)

  def index(conn, _params) do
    render(conn, "index.html", grants: ApiAuth.list_grants(conn.assigns.current_user))
  end

  def delete(conn, %{"id" => id}) do
    case ApiAuth.get_grant(conn.assigns.current_user, id) do
      nil ->
        VutuvWeb.ControllerHelpers.render_error(conn, 404)

      grant ->
        ApiAuth.revoke_grant!(grant)

        conn
        |> put_flash(
          :info,
          gettext("\"%{name}\" no longer has access to your account.", name: grant.app.name)
        )
        |> redirect(to: ~p"/connected_apps")
    end
  end
end
