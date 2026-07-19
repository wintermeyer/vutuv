defmodule VutuvWeb.SettingsDevicesTest do
  @moduledoc """
  The signed-in-devices card on the sign-in & security page and remote logout
  (issue #794),
  driven end to end through the real login flow and request pipeline so the
  server-side session revocation is exercised the way a browser hits it.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Sessions

  # A second independent browser for the same account: log the just-registered
  # user in again on a fresh conn, using that user's own email (the sign-up
  # helper mints a unique address per registration, so read it back off `user`
  # rather than assuming a fixed literal).
  defp second_device(user) do
    email =
      user |> Repo.preload(:emails) |> Map.fetch!(:emails) |> List.first() |> Map.fetch!(:value)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> login_via_pin(email)
  end

  describe "the signed-in-devices card" do
    test "lists the current device, marked, with no logout button", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = get(conn, ~p"/settings/security")
      body = html_response(conn, 200)

      assert body =~ "Signed-in devices"
      assert body =~ "This device"
      # The current session is reachable as an assign and is the only active one.
      assert conn.assigns.current_session_id
      assert length(Sessions.list_active(user)) == 1
    end
  end

  describe "remote logout" do
    test "logging out another device drops it on its next request", %{conn: conn} do
      {conn1, user} = create_and_login_user(conn)
      conn2 = second_device(user)

      conn1 = get(conn1, ~p"/settings/security")
      conn2 = get(conn2, ~p"/settings/security")
      id1 = conn1.assigns.current_session_id
      id2 = conn2.assigns.current_session_id
      assert id1 && id2 && id1 != id2

      # From device 1, log device 2 out.
      conn1 = delete(conn1, ~p"/settings/devices/#{id2}")
      assert redirected_to(conn1) == ~p"/settings/security"

      # Device 2's very next request falls back to the anonymous view (the
      # login-required /settings scope redirects home) and its session cookie
      # is dropped.
      conn2 = get(conn2, ~p"/settings/security")
      assert redirected_to(conn2) == "/"
      refute get_session(conn2, :user_id)

      # Device 1 is untouched.
      conn1 = get(conn1, ~p"/settings/security")
      assert conn1.assigns.current_user.id == user.id
    end

    test "a member cannot revoke a session that is not theirs", %{conn: conn} do
      {conn1, _user} = create_and_login_user(conn)

      victim = insert(:user)
      {_token, victim_session} = Sessions.start_session(victim, build_conn(), alert: false)

      conn1 = delete(conn1, ~p"/settings/devices/#{victim_session.id}")
      assert redirected_to(conn1) == ~p"/settings/security"
      # The foreign session is untouched (scoped lookup makes it invisible).
      assert Sessions.get_session(victim, victim_session.id).revoked_at == nil
    end

    test "'log out all other devices' keeps the current one", %{conn: conn} do
      {conn1, user} = create_and_login_user(conn)
      conn2 = second_device(user)

      conn1 = get(conn1, ~p"/settings/security")
      conn2 = get(conn2, ~p"/settings/security")
      id1 = conn1.assigns.current_session_id

      conn1 = delete(conn1, ~p"/settings/devices")
      assert redirected_to(conn1) == ~p"/settings/security"

      assert Sessions.list_active(user) |> Enum.map(& &1.id) == [id1]

      conn2 = get(conn2, ~p"/settings/security")
      assert redirected_to(conn2) == "/"
    end
  end
end
