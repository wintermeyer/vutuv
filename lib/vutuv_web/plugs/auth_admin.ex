defmodule VutuvWeb.Plug.AuthAdmin do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  def init(opts) do
    opts
  end

  def call(conn, _default) do
    admin?(conn, conn.assigns[:current_user])
  end

  defp admin?(conn, %Vutuv.Accounts.User{administrator: false}), do: forbidden(conn)

  defp admin?(conn, %Vutuv.Accounts.User{administrator: true}), do: conn

  defp admin?(conn, _), do: forbidden(conn)

  defp forbidden(conn) do
    conn
    |> put_status(403)
    |> put_view(html: VutuvWeb.ErrorHTML)
    |> render("403.html")
    |> halt
  end
end
