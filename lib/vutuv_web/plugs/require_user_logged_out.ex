defmodule VutuvWeb.Plug.RequireUserLoggedOut do
  @moduledoc false

  import Plug.Conn

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico robots.txt)

  def init(default), do: default

  def call(conn, _default) do
    logged_in?(conn, get_session(conn, :user_id))
  end

  defp logged_in?(conn, nil), do: conn

  defp logged_in?(conn, _) do
    redirect(conn, conn.assigns[:current_user])
  end

  defp redirect(conn, nil), do: conn

  defp redirect(conn, user) do
    conn
    |> Phoenix.Controller.redirect(to: ~p"/#{user}")
    |> halt
  end
end
