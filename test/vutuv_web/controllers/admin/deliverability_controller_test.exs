defmodule VutuvWeb.Admin.DeliverabilityControllerTest do
  @moduledoc """
  The admin deliverability dashboard: admins-only, lists frozen accounts and
  dead addresses, and can undo both (thaw an account, clear an address mark).
  """
  use VutuvWeb.ConnCase

  import Ecto.Query

  alias Vutuv.Accounts.{Email, User}
  alias Vutuv.Deliverability
  alias Vutuv.Repo

  defp frozen_user do
    user = insert(:activated_user)
    insert(:email, user: user, value: "dead@example.com")

    past_grace =
      NaiveDateTime.add(
        NaiveDateTime.utc_now(:second),
        -(Deliverability.grace_days() + 1) * 86_400,
        :second
      )

    Repo.update_all(from(e in Email, where: e.value == "dead@example.com"),
      set: [undeliverable_at: past_grace]
    )

    Deliverability.reassess_user(user)
    Repo.get!(User, user.id)
  end

  describe "authorization" do
    test "non-admins are locked out", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/deliverability"), 403)
    end
  end

  describe "index" do
    test "lists frozen accounts and deactivated addresses", %{conn: conn} do
      user = frozen_user()
      {conn, _admin} = create_and_login_admin(conn)

      response = html_response(get(conn, ~p"/admin/deliverability"), 200)
      assert response =~ "Frozen accounts"
      assert response =~ "dead@example.com"
      assert response =~ user.username
    end
  end

  describe "thaw" do
    test "lifts a deliverability freeze", %{conn: conn} do
      user = frozen_user()
      assert user.unreachable_at
      {conn, _admin} = create_and_login_admin(conn)

      conn = post(conn, ~p"/admin/deliverability/users/#{user.id}/thaw")
      assert redirected_to(conn) == ~p"/admin/deliverability"
      refute Repo.get!(User, user.id).unreachable_at
    end

    test "404 for an unknown account", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      conn = post(conn, ~p"/admin/deliverability/users/#{Vutuv.UUIDv7.generate()}/thaw")
      assert html_response(conn, 404)
    end
  end

  describe "clear address" do
    test "clears the undeliverable mark and re-assesses the owner", %{conn: conn} do
      user = frozen_user()
      email = Repo.get_by!(Email, value: "dead@example.com")
      {conn, _admin} = create_and_login_admin(conn)

      conn = post(conn, ~p"/admin/deliverability/emails/#{email.id}/clear")
      assert redirected_to(conn) == ~p"/admin/deliverability"
      refute Repo.get!(Email, email.id).undeliverable_at
      refute Repo.get!(User, user.id).unreachable_at
    end
  end
end
