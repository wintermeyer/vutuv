defmodule VutuvWeb.Plug.AuthAdmin do
  @moduledoc false

  def init(opts) do
    opts
  end

  def call(conn, _default) do
    admin?(conn, conn.assigns[:current_user])
  end

  defp admin?(conn, %Vutuv.Accounts.User{administrator: true}), do: conn

  defp admin?(conn, _), do: VutuvWeb.ControllerHelpers.render_error(conn, 403)
end
