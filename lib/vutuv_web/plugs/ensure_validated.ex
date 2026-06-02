defmodule VutuvWeb.Plug.EnsureValidated do
  @moduledoc false

  import Plug.Conn

  def init(opts) do
    opts
  end

  def call(conn, _opts) do
    conn.assigns[:user]
    |> validated?(conn)
  end

  defp validated?(%Vutuv.Accounts.User{validated?: true}, conn), do: conn

  defp validated?(%Vutuv.Accounts.User{validated?: nil}, conn), do: conn

  defp validated?(_, conn), do: not_found(conn)

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> Phoenix.Controller.put_view(html: VutuvWeb.ErrorHTML)
    |> Phoenix.Controller.render("404.html")
    |> halt
  end
end
