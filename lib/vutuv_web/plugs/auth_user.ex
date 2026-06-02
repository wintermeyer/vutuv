defmodule VutuvWeb.Plug.AuthUser do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  def init(opts) do
    opts
  end

  def call(conn, _default) do
    current_user = conn.assigns[:current_user]
    user = conn.assigns[:user]

    if current_user && user && user.id == current_user.id do
      conn
    else
      conn
      |> put_status(403)
      |> put_view(html: VutuvWeb.ErrorHTML)
      |> render("403.html")
      |> halt
    end
  end
end
