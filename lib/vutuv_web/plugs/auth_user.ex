defmodule VutuvWeb.Plug.AuthUser do
  @moduledoc false

  def init(opts) do
    opts
  end

  def call(conn, _default) do
    current_user = conn.assigns[:current_user]
    user = conn.assigns[:user]

    if current_user && user && user.id == current_user.id do
      conn
    else
      VutuvWeb.ControllerHelpers.render_error(conn, 403)
    end
  end
end
