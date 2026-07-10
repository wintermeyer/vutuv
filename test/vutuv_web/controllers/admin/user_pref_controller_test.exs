defmodule VutuvWeb.Admin.UserPrefControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Accounts.User
  alias Vutuv.Prefs

  test "a logged-in non-admin is refused", %{conn: conn} do
    member = insert(:user)
    {conn, _user} = create_and_login_user(conn)

    conn = get(conn, ~p"/admin/users/#{member.id}/preferences")
    assert html_response(conn, 403)
  end

  test "an unknown member 404s", %{conn: conn} do
    {conn, _admin} = create_and_login_admin(conn)

    conn = get(conn, ~p"/admin/users/#{Vutuv.UUIDv7.generate()}/preferences")
    assert html_response(conn, 404)
  end

  describe "show" do
    setup [:admin_and_member]

    test "renders every registry pref with an inherit option", %{conn: conn, member: member} do
      conn = get(conn, ~p"/admin/users/#{member.id}/preferences")
      html = html_response(conn, 200)

      assert html =~ member.username

      for pref <- Prefs.registry() do
        assert html =~ ~s(id="pref_#{pref.key}"),
               "no control for #{pref.key} on the member override page"
      end

      # The form posts back to this member's override page (assert the
      # rendered action=, per the form-URL lesson from v7.34-v7.42).
      assert html =~ ~s(action="/admin/users/#{member.id}/preferences")
    end

    test "marks a member's explicit value as their own choice", %{conn: conn, member: member} do
      {:ok, member} = Prefs.admin_update_user(member, %{"post_lines_desktop" => "3"})

      conn = get(conn, ~p"/admin/users/#{member.id}/preferences")
      html = html_response(conn, 200)

      assert html =~ ~s(value="3")
      assert html =~ ~s(data-pref-source="own")
    end
  end

  describe "update" do
    setup [:admin_and_member]

    test "sets explicit values for the member", %{conn: conn, member: member} do
      conn =
        put(conn, ~p"/admin/users/#{member.id}/preferences",
          prefs: %{"post_lines_desktop" => "3", "default_map_service" => "apple"}
        )

      assert redirected_to(conn) == ~p"/admin/users/#{member.id}/preferences"

      member = Repo.get!(User, member.id)
      assert member.post_lines_desktop == 3
      assert member.default_map_service == "apple"
    end

    test "a blank clears the member's value back to inherit", %{conn: conn, member: member} do
      {:ok, member} =
        Prefs.admin_update_user(member, %{
          "post_lines_desktop" => "3",
          "post_hyphenate_desktop" => "true"
        })

      conn =
        put(conn, ~p"/admin/users/#{member.id}/preferences",
          prefs: %{"post_lines_desktop" => "", "post_hyphenate_desktop" => ""}
        )

      assert redirected_to(conn) == ~p"/admin/users/#{member.id}/preferences"

      member = Repo.get!(User, member.id)
      assert member.post_lines_desktop == nil
      assert member.post_hyphenate_desktop == nil
    end

    test "an invalid value re-renders with the field marked and writes nothing", %{
      conn: conn,
      member: member
    } do
      conn =
        put(conn, ~p"/admin/users/#{member.id}/preferences",
          prefs: %{"post_lines_desktop" => "999"}
        )

      html = html_response(conn, 422)
      assert html =~ ~s(value="999")
      assert Repo.get!(User, member.id).post_lines_desktop == nil
    end
  end

  defp admin_and_member(%{conn: conn}) do
    {conn, admin} = create_and_login_admin(conn)
    %{conn: conn, admin: admin, member: insert(:user)}
  end
end
