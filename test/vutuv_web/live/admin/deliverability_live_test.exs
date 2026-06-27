defmodule VutuvWeb.Admin.DeliverabilityLiveTest do
  @moduledoc """
  The admin deliverability dashboard LiveView (`/admin/deliverability`):
  admins-only, lists frozen accounts and dead addresses, and undoes both
  (thaw an account, clear an address mark) reload-free over the socket. The
  classic CSRF POST routes stay as the no-JS / scriptable fallback and are
  covered by `DeliverabilityControllerTest`.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

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

  describe "listing" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "lists frozen accounts and deactivated addresses", %{conn: conn} do
      user = frozen_user()

      {:ok, _lv, html} = live(conn, ~p"/admin/deliverability")

      assert html =~ "Frozen accounts"
      assert html =~ "dead@example.com"
      assert html =~ user.username
    end
  end

  describe "thaw" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "thaws the account in place and persists, no reload", %{conn: conn} do
      user = frozen_user()
      assert user.unreachable_at

      {:ok, lv, _html} = live(conn, ~p"/admin/deliverability")
      assert has_element?(lv, "#frozen-#{user.id}")

      lv
      |> element(~s|button[phx-click="thaw"][phx-value-id="#{user.id}"]|)
      |> render_click()

      refute has_element?(lv, "#frozen-#{user.id}")
      refute Repo.get!(User, user.id).unreachable_at
    end
  end

  describe "clear address" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "clears the undeliverable mark and re-assesses the owner, no reload", %{conn: conn} do
      user = frozen_user()
      email = Repo.get_by!(Email, value: "dead@example.com")

      {:ok, lv, _html} = live(conn, ~p"/admin/deliverability")
      assert has_element?(lv, "#deactivated-#{email.id}")

      lv
      |> element(~s|button[phx-click="clear"][phx-value-id="#{email.id}"]|)
      |> render_click()

      refute has_element?(lv, "#deactivated-#{email.id}")
      refute Repo.get!(Email, email.id).undeliverable_at
      refute Repo.get!(User, user.id).unreachable_at
    end
  end
end
