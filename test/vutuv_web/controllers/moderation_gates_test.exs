defmodule VutuvWeb.ModerationGatesTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Accounts.User

  defp set_user!(user, fields) do
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: fields)
    Repo.get!(User, user.id)
  end

  describe "frozen profile page" do
    setup %{conn: conn} do
      owner = insert_activated_user(frozen_at: NaiveDateTime.utc_now(:second))
      {:ok, %{conn: conn, owner: owner}}
    end

    test "404s for visitors", %{conn: conn, owner: owner} do
      conn = get(conn, ~p"/#{owner}")
      assert html_response(conn, 404)
    end

    test "404s for other logged-in members", %{conn: conn, owner: owner} do
      {conn, _user} = create_and_login_user(conn)
      conn = get(conn, ~p"/#{owner}")
      assert html_response(conn, 404)
    end

    test "stays reachable for the owner", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      set_user!(me, frozen_at: NaiveDateTime.utc_now(:second))

      conn = get(conn, ~p"/#{me}")
      assert html_response(conn, 200)
    end

    test "stays reachable for admins", %{conn: conn, owner: owner} do
      {conn, _admin} = create_and_login_admin(conn)
      conn = get(conn, ~p"/#{owner}")
      assert html_response(conn, 200)
    end
  end

  describe "login blocks" do
    setup %{conn: conn} do
      user = insert_activated_user()
      insert(:email, user: user, value: "blocked@example.com")
      {:ok, %{conn: conn, user: user}}
    end

    test "a deactivated account cannot log in", %{conn: conn, user: user} do
      set_user!(user, deactivated_at: NaiveDateTime.utc_now(:second))

      conn = login_via_pin(conn, "blocked@example.com")

      assert redirected_to(conn) == "/"
      refute get_session(conn, :user_id)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "deactivated"
    end

    test "a suspended account cannot log in until the suspension lapses", %{
      conn: conn,
      user: user
    } do
      until = NaiveDateTime.add(NaiveDateTime.utc_now(:second), 7 * 86_400)
      set_user!(user, suspended_until: until)

      conn = login_via_pin(conn, "blocked@example.com")

      assert redirected_to(conn) == "/"
      refute get_session(conn, :user_id)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "suspended"
    end

    test "a lapsed suspension logs in normally", %{conn: conn, user: user} do
      set_user!(user, suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600))

      conn = login_via_pin(conn, "blocked@example.com")

      assert get_session(conn, :user_id) == user.id
    end

    test "an existing session dies when the account is suspended", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      set_user!(user,
        suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(:second), 86_400)
      )

      conn = get(conn, ~p"/")
      assert conn.assigns.current_user == nil
    end
  end
end
