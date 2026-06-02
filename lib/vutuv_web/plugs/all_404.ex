defmodule VutuvWeb.Plug.All404 do
  @moduledoc false

  import Plug.Conn

  def init(opts) do
    opts
  end

  def call(conn, _) do
    conn
    |> put_status(404)
    |> Phoenix.Controller.put_view(html: VutuvWeb.ErrorHTML)
    |> Phoenix.Controller.render("404.html")
    |> halt
  end
end
