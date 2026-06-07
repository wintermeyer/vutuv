defmodule VutuvWeb.Plug.ConfigureSession do
  @moduledoc false

  import Plug.Conn

  def init(opts) do
    Keyword.fetch!(opts, :repo)
  end

  def call(conn, repo) do
    # cast_or_nil: cookies from before the UUID v7 cutover hold integer user
    # ids — treat them as logged out instead of raising a CastError.
    user_id = conn |> get_session(:user_id) |> Vutuv.UUIDv7.cast_or_nil()
    user = user_id && repo.get(Vutuv.Accounts.User, user_id)

    conn
    |> assign(:current_user, user)
    |> assign(:current_user_id, get_user_id(user))
  end

  defp get_user_id(%Vutuv.Accounts.User{id: id}), do: id
  defp get_user_id(_), do: nil
end
