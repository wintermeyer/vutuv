defmodule VutuvWeb.Plug.RequireUserLoggedOut do
  @moduledoc false

  import Plug.Conn

  alias VutuvWeb.Home

  def init(default), do: default

  def call(conn, _default) do
    logged_in?(conn, get_session(conn, :user_id))
  end

  defp logged_in?(conn, nil), do: conn

  defp logged_in?(conn, _) do
    redirect(conn, conn.assigns[:current_user])
  end

  defp redirect(conn, nil), do: conn

  # A logged-in visitor on a logged-out-only page (the landing page, /login,
  # registration) belongs on their home: the newsfeed once they follow someone,
  # otherwise their own profile (VutuvWeb.Home decides).
  defp redirect(conn, user) do
    conn
    |> Phoenix.Controller.redirect(to: Home.path(user))
    |> halt
  end
end
