defmodule VutuvWeb.Plug.EnsureActivated do
  @moduledoc false

  def init(opts) do
    opts
  end

  def call(conn, _opts) do
    conn.assigns[:user]
    |> activated?(conn)
  end

  defp activated?(%Vutuv.Accounts.User{activated?: true}, conn), do: conn

  defp activated?(%Vutuv.Accounts.User{activated?: nil}, conn), do: conn

  defp activated?(_, conn), do: VutuvWeb.ControllerHelpers.render_error(conn, 404)
end
