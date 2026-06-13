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
    # A suspension or deactivation must also end already-running sessions,
    # not just block new logins.
    user = if user && Vutuv.Moderation.login_block(user), do: nil, else: user

    conn =
      if user_id && is_nil(user) do
        # The cookie points at a user who may no longer log in (deleted,
        # suspended, deactivated): end the session and also kill any live
        # sockets it still has open in other tabs.
        VutuvWeb.Endpoint.broadcast("users_socket:#{user_id}", "disconnect", %{})
        delete_session(conn, :user_id)
      else
        conn
      end

    conn
    |> assign(:current_user, user)
    |> assign(:current_user_id, get_user_id(user))
  end

  defp get_user_id(%Vutuv.Accounts.User{id: id}), do: id
  defp get_user_id(_), do: nil
end
