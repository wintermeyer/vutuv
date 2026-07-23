defmodule VutuvWeb.Live.InitAssigns do
  @moduledoc """
  LiveView `on_mount` hook that mirrors `VutuvWeb.Plug.ConfigureSession` for the
  socket: it resolves the session's `session_token` against the server-side
  session rows (so a revoked device and a suspended account lose the socket the
  same way they lose a request) and assigns `:current_user`, so LiveViews and
  the shared `app` layout can render the logged-in chrome the same way classic
  controller pages do. It also mirrors `VutuvWeb.Plug.Locale`, so gettext speaks
  the visitor's language in the LiveView process too.

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
  alias Vutuv.Moderation
  alias Vutuv.Sessions

  def on_mount(:default, _params, session, socket) do
    user = session_user(session)
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
  The shared `mount/3` preamble for the **off-router** LiveViews (embedded by
  a controller via `live_render`, so no `on_mount` hook runs): resolves the
  current user from the session token, applies the visitor's locale
  (`VutuvWeb.LiveLocale`), and assigns the keys every embedded page and the
  shared `app` layout read — `:current_user`, `:current_user_id`, `:locale`
  (the "Other formats" `?lang=` suffix) and `:shell_path` (so the embedded
  ShellLive can zero the page's unread badge); the controller hands the last
  two through the session. Read the loaded user back from
  `socket.assigns.current_user`.
  """
  def assign_embedded(socket, session) do
    user = session_user(session)
    VutuvWeb.LiveLocale.put_locale(user, session)

    socket
    |> assign(:current_user, user)
    |> assign(:current_user_id, user && user.id)
    |> assign(:locale, session["locale"])
    |> assign(:shell_path, session["request_path"])
  end

  # The one place a mount decides who the visitor is, shared by the `:default`
  # hook and the off-router LiveViews. It resolves the **cookie** session's
  # `session_token` — LiveView merges the cookie session into the mount session,
  # so nothing has to pass it along — through the server-side session rows, the
  # same revocation check `VutuvWeb.Plug.ConfigureSession` runs on every
  # request, and refuses a suspended or deactivated member. Unlike the plug it
  # has no side effects: a mount cannot rewrite the cookie, and an unauthorized
  # socket simply staying anonymous is the right outcome (`:require_login` /
  # `:require_admin` then redirect).
  #
  # There is deliberately **no** fallback to a bare `session["user_id"]`.
  # `user_id` is not only a cookie value: a controller-curated `live_render`
  # session map carries it too and is merged *over* the cookie session, and that
  # map travels in `data-phx-session`, which is signed but not encrypted and
  # stays valid for days. Honoring `user_id` without a token would therefore let
  # a captured payload, replayed with a cookie holding no token, authenticate as
  # the member it names, with no revocation check at all.
  defp session_user(session) when is_map(session) do
    case Sessions.active_session(Map.get(session, "session_token")) do
      %{user: %User{} = user} -> if allowed?(user), do: user, else: nil
      _ -> nil
    end
  end

  defp session_user(_session), do: nil

  # Mirrors the plug's own gate: a suspension or deactivation must end running
  # sessions, not just block new logins.
  defp allowed?(%User{} = user), do: is_nil(Moderation.login_block(user))
end
