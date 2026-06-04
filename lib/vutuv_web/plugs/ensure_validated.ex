defmodule VutuvWeb.Plug.EnsureValidated do
  @moduledoc false

  def init(opts) do
    opts
  end

  def call(conn, _opts) do
    conn.assigns[:user]
    |> validated?(conn)
  end

  defp validated?(%Vutuv.Accounts.User{validated?: true}, conn), do: conn

  defp validated?(%Vutuv.Accounts.User{validated?: nil}, conn), do: conn

  defp validated?(_, conn), do: VutuvWeb.ControllerHelpers.render_error(conn, 404)
end
