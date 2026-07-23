defmodule VutuvWeb.Live.InitAssignsTest do
  @moduledoc """
  The LiveView mount must authenticate exactly like `VutuvWeb.Plug.Configure
  Session` does for a request: through the cookie's `session_token`, so a
  remotely logged-out device and a suspended or deactivated member lose the
  socket too, and never through a bare `user_id` — that key also arrives from
  the controller-curated `live_render` session map, which is signed but not
  encrypted and can therefore be captured and replayed.

  The sessions here are the real thing: the cookie session read off a conn that
  went through the actual PIN login, optionally merged with a curated map the
  way `Phoenix.LiveView` merges one over the cookie session at mount.
  """
  use VutuvWeb.ConnCase, async: true

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket
  alias Vutuv.Accounts.User
  alias Vutuv.Sessions
  alias VutuvWeb.Live.InitAssigns

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, conn: conn, user: user, session: Plug.Conn.get_session(conn)}
  end

  defp set_user!(user, fields) do
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: fields)
    Repo.get!(User, user.id)
  end

  # A socket as it reaches an `on_mount` hook: mounted at the router (the
  # `:default` stage attaches a `:handle_params` hook) with an empty lifecycle.
  defp mount_socket do
    %Socket{
      router: VutuvWeb.Router,
      endpoint: VutuvWeb.Endpoint,
      private: %{live_temp: %{}, lifecycle: %Lifecycle{}}
    }
  end

  defp mounted_user(session) do
    assert {:cont, socket} = InitAssigns.on_mount(:default, %{}, session, mount_socket())
    socket.assigns.current_user
  end

  defp embedded_user(session) do
    InitAssigns.assign_embedded(%Socket{}, session).assigns.current_user
  end

  describe "an active session token" do
    test "authenticates the on_mount hook", %{session: session, user: user} do
      assert %User{id: id} = mounted_user(session)
      assert id == user.id
    end

    test "authenticates an embedded LiveView", %{session: session, user: user} do
      socket = InitAssigns.assign_embedded(%Socket{}, session)

      assert socket.assigns.current_user.id == user.id
      assert socket.assigns.current_user_id == user.id
    end
  end

  describe "a token the server no longer honors" do
    test "a revoked session mounts anonymous", %{session: session, user: user} do
      assert [device] = Sessions.list_active(user)
      Sessions.revoke(device)

      refute mounted_user(session)
      refute embedded_user(session)
    end

    test "a suspended member mounts anonymous", %{session: session, user: user} do
      set_user!(user, suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(:second), 86_400))

      refute mounted_user(session)
      refute embedded_user(session)
    end

    test "a deactivated member mounts anonymous", %{session: session, user: user} do
      set_user!(user, deactivated_at: NaiveDateTime.utc_now(:second))

      refute mounted_user(session)
      refute embedded_user(session)
    end

    test "an unknown token mounts anonymous", %{session: session} do
      session = Map.put(session, "session_token", "not-a-real-token")

      refute mounted_user(session)
      refute embedded_user(session)
    end
  end

  describe "a session with no token" do
    test "a valid user_id alone never authenticates", %{session: session, user: user} do
      session = Map.delete(session, "session_token")

      # The identity the cookie still names is a real, active member — and it
      # is still refused, because nothing proves the session was not revoked.
      assert session["user_id"] == user.id
      refute mounted_user(session)
      refute embedded_user(session)
    end

    test "an embedded mount ignores a page-supplied user_id", %{conn: conn, user: user} do
      # The replay: an anonymous visitor's own cookie session (no token) with a
      # captured `data-phx-session` curated map merged over it, exactly the way
      # `VutuvWeb.ControllerHelpers.live_render_session/1` builds one.
      anonymous_session =
        build_conn() |> Plug.Test.init_test_session(%{}) |> Plug.Conn.get_session()

      curated = %{
        "user_id" => user.id,
        "locale" => "de",
        "request_path" => "/#{user.username}"
      }

      session = Map.merge(anonymous_session, curated)

      refute embedded_user(session)
      refute mounted_user(session)

      # The legitimate visitor keeps their own session: the same curated map
      # over a logged-in cookie session still resolves through the token.
      logged_in = Map.merge(Plug.Conn.get_session(conn), curated)
      assert embedded_user(logged_in).id == user.id
    end
  end

  describe "no session at all" do
    test "an anonymous session mounts anonymous" do
      refute mounted_user(%{})
      refute embedded_user(%{})
    end

    test "a malformed session mounts anonymous" do
      refute mounted_user(%{"session_token" => 12_345})
      refute embedded_user(%{"session_token" => %{"nested" => true}})
      refute embedded_user(nil)
    end
  end
end
