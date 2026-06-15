defmodule VutuvWeb.Plug.ConfigureSession do
  @moduledoc """
  Resolves the current user from the session cookie on every request, and
  enforces server-side session revocation (issue #794).

  A logged-in cookie carries a `session_token`. Each request looks the matching
  `Vutuv.Sessions.UserSession` up by its hash: a missing or revoked row means
  the device was logged out remotely, so the cookie is dropped and that device's
  live sockets are killed. An active row bumps `last_seen_at` (throttled) and
  exposes `current_session_id` so the settings page can mark "this device".

  A cookie with a `user_id` but **no** `session_token` is a legacy session
  minted before this feature (or by the previous release during an N-1 deploy).
  Rather than log everyone out, it is honored and lazily upgraded: a session row
  is minted for it (silently — no security email), so it joins the device list
  on the next request.
  """

  import Plug.Conn

  alias Vutuv.Accounts.User
  alias Vutuv.Sessions

  def init(opts) do
    Keyword.fetch!(opts, :repo)
  end

  def call(conn, repo) do
    token = get_session(conn, :session_token)
    # cast_or_nil: cookies from before the UUID v7 cutover hold integer user
    # ids — treat them as logged out instead of raising a CastError.
    user_id = conn |> get_session(:user_id) |> Vutuv.UUIDv7.cast_or_nil()

    {conn, user} = resolve(conn, repo, token, user_id)

    conn
    |> assign(:current_user, user)
    |> assign(:current_user_id, get_user_id(user))
  end

  # A tracked session: trust the row, not the bare user_id.
  defp resolve(conn, _repo, token, _user_id) when is_binary(token) do
    case Sessions.active_session(token) do
      %{user: %User{} = user} = session ->
        if allowed?(user) do
          Sessions.touch(session)
          {assign(conn, :current_session_id, session.id), user}
        else
          # Suspended/deactivated mid-session: end every device, not just this
          # one (a single revoked row would leave the others logged in).
          Sessions.disconnect_user(user.id)
          {drop_login(conn), nil}
        end

      _ ->
        # Token unknown or revoked: the device was logged out remotely (or the
        # account was deleted). Drop the cookie; the live socket was already
        # disconnected when it was revoked.
        {drop_login(conn), nil}
    end
  end

  # A legacy cookie (no session token): honor the user_id and lazily upgrade.
  defp resolve(conn, repo, _no_token, user_id) when is_binary(user_id) do
    case repo.get(User, user_id) do
      %User{} = user ->
        if allowed?(user) do
          lazily_upgrade(conn, user)
        else
          Sessions.disconnect_user(user.id)
          {drop_login(conn), nil}
        end

      nil ->
        # The cookie points at a deleted user: end the session and kill any live
        # sockets it still has open in other tabs. Same fan-out as the
        # suspended/deactivated branches (per-session topics + the legacy one).
        Sessions.disconnect_user(user_id)
        {delete_session(conn, :user_id), nil}
    end
  end

  defp resolve(conn, _repo, _no_token, _no_user), do: {conn, nil}

  # Mint a tracked session for a still-valid legacy cookie so it gains a device
  # row and per-session socket. Silent (alert: false) — a deploy must not blast
  # every returning member with a "new device" email.
  defp lazily_upgrade(conn, user) do
    {token, session} = Sessions.start_session(user, conn, alert: false)

    conn =
      conn
      |> put_session(:session_token, token)
      |> put_session(:live_socket_id, Sessions.socket_id(session))
      |> assign(:current_session_id, session.id)

    {conn, user}
  end

  # A suspension or deactivation must end already-running sessions, not just
  # block new logins.
  defp allowed?(%User{} = user), do: is_nil(Vutuv.Moderation.login_block(user))

  defp drop_login(conn) do
    conn
    |> delete_session(:user_id)
    |> delete_session(:session_token)
  end

  defp get_user_id(%User{id: id}), do: id
  defp get_user_id(_), do: nil
end
