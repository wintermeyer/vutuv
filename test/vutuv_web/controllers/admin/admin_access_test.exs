defmodule VutuvWeb.Admin.AdminAccessTest do
  use VutuvWeb.ConnCase

  # The admin area 403s for everyone but admins - but a logged-in member who
  # wonders "how does one become an admin here?" deserves an answer instead
  # of a bare error: admin rights are granted by the instance operator,
  # directly in the database.

  test "a logged-in non-admin gets the how-to-become-admin explanation", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    conn = get(conn, ~p"/admin")
    html = html_response(conn, 403)

    assert html =~ "reserved for administrators"
    assert html =~ "administrator = TRUE"
    assert html =~ ~p"/impressum"
  end

  test "anonymous visitors are redirected away, no explanation", %{conn: conn} do
    conn = get(conn, ~p"/admin")

    assert redirected_to(conn)
    refute conn.resp_body =~ "administrator = TRUE"
  end

  test "an admin passes through", %{conn: conn} do
    {conn, _admin} = create_and_login_admin(conn)

    conn = get(conn, ~p"/admin")
    assert html_response(conn, 200)
  end
end
