defmodule VutuvWeb.Admin.UserDeleteLiveTest do
  @moduledoc """
  The admin "delete account" LiveView (`/admin/users/delete`): admins-only,
  search-as-you-type by name/@handle/email, then delete an account behind an
  "Are you sure?" modal. Deletion removes everything the account owns, emails
  the operator, and never emails the deleted member.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Vutuv.PostsHelpers, only: [create_post!: 2]

  alias Vutuv.Accounts.User

  describe "authorization" do
    test "non-admins are locked out", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/users/delete"), 403)
    end
  end

  describe "search" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "starts empty and prompts for a search", %{conn: conn} do
      insert(:activated_user, username: "zaphod")

      {:ok, _lv, html} = live(conn, ~p"/admin/users/delete")

      refute html =~ "zaphod"
      assert html =~ "Type a name"
    end

    test "search-as-you-type lists matching accounts only", %{conn: conn} do
      insert(:activated_user, first_name: "Zaphod", last_name: "Beeblebrox", username: "zaphod")
      insert(:activated_user, first_name: "Arthur", last_name: "Dent", username: "arthurdent")

      {:ok, lv, _html} = live(conn, ~p"/admin/users/delete")

      html = lv |> form("#user-search", %{q: "Beeblebrox"}) |> render_change()

      assert html =~ "zaphod"
      refute html =~ "arthurdent"
    end

    test "finds an account by its email address", %{conn: conn} do
      user = insert(:activated_user, username: "zaphod")
      insert(:email, user: user, value: "heart-of-gold@example.com")

      {:ok, lv, _html} = live(conn, ~p"/admin/users/delete")
      html = lv |> form("#user-search", %{q: "heart-of-gold@example.com"}) |> render_change()

      assert html =~ "zaphod"
    end
  end

  describe "delete flow" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "Delete opens the confirmation modal", %{conn: conn} do
      user = insert(:activated_user, username: "zaphod")

      {:ok, lv, _html} = live(conn, ~p"/admin/users/delete")
      lv |> form("#user-search", %{q: "zaphod"}) |> render_change()

      refute has_element?(lv, "#delete-modal")

      lv |> element("#user-#{user.id} button", "Delete") |> render_click()

      assert has_element?(lv, "#delete-modal")
      assert has_element?(lv, "#confirm-delete")
    end

    test "Cancel closes the modal without deleting", %{conn: conn} do
      user = insert(:activated_user, username: "zaphod")

      {:ok, lv, _html} = live(conn, ~p"/admin/users/delete")
      lv |> form("#user-search", %{q: "zaphod"}) |> render_change()
      lv |> element("#user-#{user.id} button", "Delete") |> render_click()

      lv |> element("#delete-modal button", "Cancel") |> render_click()

      refute has_element?(lv, "#delete-modal")
      assert Repo.get(User, user.id)
    end

    test "confirming deletes the account, drops the row, and emails the operator", %{conn: conn} do
      user = insert(:activated_user, username: "zaphod")
      insert(:email, user: user, value: "victim@example.com")
      insert(:phone_number, user: user, value: "+49 30 5551234")
      create_post!(user, %{body: "goodbye"})

      {:ok, lv, _html} = live(conn, ~p"/admin/users/delete")
      lv |> form("#user-search", %{q: "zaphod"}) |> render_change()
      lv |> element("#user-#{user.id} button", "Delete") |> render_click()

      html = lv |> element("#confirm-delete") |> render_click()

      # The account is gone and the row is dropped from the list.
      refute Repo.get(User, user.id)
      refute has_element?(lv, "#user-#{user.id}")
      refute html =~ "delete-modal"

      # The operator is notified; the deleted member is not.
      assert_email_sent(fn email ->
        assert email.to == [{"Stefan Wintermeyer", "sw@wintermeyer-consulting.de"}]
        assert email.text_body =~ "victim@example.com"
        true
      end)

      refute_email_sent(%{to: [{_, "victim@example.com"}]})
    end
  end
end
