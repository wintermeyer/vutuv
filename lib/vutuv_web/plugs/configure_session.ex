defmodule VutuvWeb.Plug.ConfigureSession do
  @moduledoc false

  import Plug.Conn

  def init(opts) do
    Keyword.fetch!(opts, :repo)
  end

  def call(conn, repo) do
    user_id = get_session(conn, :user_id)
    user = user_id && repo.get(Vutuv.Accounts.User, user_id)

    conn
    |> assign(:current_user, user)
    |> assign(:current_user_id, get_user_id(user))
  end

  defp get_user_id(%Vutuv.Accounts.User{id: id}), do: id
  defp get_user_id(_), do: nil
end
