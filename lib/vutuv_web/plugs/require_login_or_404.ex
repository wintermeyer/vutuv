defmodule VutuvWeb.Plug.RequireLoginOr404 do
  @moduledoc """
  Require a logged-in session user, rendering a clean 404 (not a redirect) when
  there is none. Deliberately distinct from `VutuvWeb.Plug.RequireLogin`, which
  redirects to the start page with a flash: these endpoints hide their existence
  from anonymous callers instead of inviting a login.
  """

  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user_id] do
      nil ->
        conn
        |> put_status(404)
        |> put_view(html: VutuvWeb.ErrorHTML)
        |> render("404.html")
        |> halt()

      _id ->
        conn
    end
  end
end
