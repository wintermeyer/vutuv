defmodule VutuvWeb.Live.InitAssigns do
  @moduledoc """
  LiveView `on_mount` hook that mirrors `VutuvWeb.Plug.ConfigureSession` for the
  socket: it reads `:user_id` from the session and assigns `:current_user`, so
  LiveViews and the shared `app` layout can render the logged-in chrome the same
  way classic controller pages do.
  """
  import Phoenix.Component, only: [assign: 3]

  alias Vutuv.Accounts.User
  alias Vutuv.Repo

  def on_mount(:default, _params, session, socket) do
    user = session |> Map.get("user_id") |> load_user()
    {:cont, assign(socket, :current_user, user)}
  end

  defp load_user(nil), do: nil
  defp load_user(user_id), do: Repo.get(User, user_id)
end
