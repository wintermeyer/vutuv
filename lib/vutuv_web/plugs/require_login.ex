defmodule VutuvWeb.Plug.RequireLogin do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller
  use Gettext, backend: VutuvWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico robots.txt)

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, gettext("You must be logged in to access that page"))
      |> redirect(to: ~p"/")
      |> halt()
    end
  end
end
