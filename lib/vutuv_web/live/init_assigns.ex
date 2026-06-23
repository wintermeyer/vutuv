defmodule VutuvWeb.Live.InitAssigns do
  @moduledoc """
  LiveView `on_mount` hook that mirrors `VutuvWeb.Plug.ConfigureSession` for the
  socket: it reads `:user_id` from the session and assigns `:current_user`, so
  LiveViews and the shared `app` layout can render the logged-in chrome the same
  way classic controller pages do. It also mirrors `VutuvWeb.Plug.Locale`, so
  gettext speaks the visitor's language in the LiveView process too.

  The `:require_login` stage mirrors `VutuvWeb.Plug.RequireLogin` for LiveViews:
  declare it module-level (`on_mount {VutuvWeb.Live.InitAssigns, :require_login}`)
  on any LiveView in the `live_session` that must not render for anonymous
  visitors, instead of hand-rolling the gate in `mount/3`.
  """
  import Phoenix.Component, only: [assign: 3]

  use Gettext, backend: VutuvWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico robots.txt)

  alias Vutuv.Accounts.User
  alias Vutuv.Repo

  def on_mount(:default, _params, session, socket) do
    user = session |> Map.get("user_id") |> load_user()
    VutuvWeb.LiveLocale.put_locale(user, session)

    # Mirror `conn.request_path` for live pages: the shared layout hands the
    # current path to the embedded ShellLive so it can zero the matching
    # unread badge at mount, without enumerating view modules.
    socket =
      socket
      |> assign(:current_user, user)
      |> Phoenix.LiveView.attach_hook(:shell_path, :handle_params, &assign_shell_path/3)

    {:cont, socket}
  end

  def on_mount(:require_login, _params, _session, socket) do
    if socket.assigns.current_user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(
          :error,
          gettext("You must be logged in to access that page")
        )
        |> Phoenix.LiveView.redirect(to: ~p"/login")

      {:halt, socket}
    end
  end

  @doc """
  The `:require_admin` stage mirrors `VutuvWeb.Plug.AuthAdmin` for LiveViews in
  an admin `live_session`. The dead `:admin` pipeline already 403s the
  disconnected render, so this is the second guard on the socket connect. Run it
  after `:default`, which assigns `:current_user`.
  """
  def on_mount(:require_admin, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %User{admin?: true} -> {:cont, socket}
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  defp assign_shell_path(_params, uri, socket) do
    {:cont, assign(socket, :shell_path, URI.parse(uri).path)}
  end

  @doc """
  Load the current user from a session `user_id`, or nil. Shared with the
  off-router `VutuvWeb.UserProfileLive`, which can't use this module as an
  on_mount hook but needs the same resolution. cast_or_nil: pre-UUID-cutover
  cookies hold integer ids — anonymous, not a CastError (mirrors
  `VutuvWeb.Plug.ConfigureSession`).
  """
  def load_user(user_id) do
    case Vutuv.UUIDv7.cast_or_nil(user_id) do
      nil -> nil
      user_id -> Repo.get(User, user_id)
    end
  end
end
