defmodule VutuvWeb.Plug.AuthAdmin do
  @moduledoc false

  def init(opts) do
    opts
  end

  def call(conn, _default) do
    admin?(conn, conn.assigns[:current_user])
  end

  defp admin?(conn, %Vutuv.Accounts.User{admin?: true}), do: conn

  # A logged-in member gets the explanation of how admin rights are granted
  # (by the operator, in the database) instead of a bare 403.
  defp admin?(conn, %Vutuv.Accounts.User{}) do
    conn
    |> Plug.Conn.put_status(403)
    |> Phoenix.Controller.put_view(html: VutuvWeb.ErrorHTML)
    |> Phoenix.Controller.render("403_admin.html")
    |> Plug.Conn.halt()
  end

  defp admin?(conn, _), do: VutuvWeb.ControllerHelpers.render_error(conn, 403)
end
