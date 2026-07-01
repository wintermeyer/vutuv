defmodule VutuvWeb.Admin.AdminDashboardIpTest do
  @moduledoc """
  The admin dashboard shows the operator the client IP as the app actually sees
  it, and warns loudly when that is a loopback/private address. It is the live
  check that nginx forwards X-Forwarded-For so the per-IP rate limiter and the
  security email work (issues #799, #837).
  """
  use VutuvWeb.ConnCase

  # Log in as admin, then GET /admin as if the request arrived from `ip`.
  # recycle/1 carries the session cookie forward but resets remote_ip, so set it
  # after recycling and mark the conn recycled so get/2 does not reset it again
  # (the same trick submit_with_csrf/3 uses).
  defp admin_dashboard_from(conn, ip) do
    {conn, _admin} = create_and_login_admin(conn)

    conn
    |> recycle()
    |> Map.put(:remote_ip, ip)
    |> Plug.Conn.put_private(:phoenix_recycled, true)
    |> get(~p"/admin")
  end

  test "shows a public client IP and no warning", %{conn: conn} do
    conn = admin_dashboard_from(conn, {203, 0, 113, 7})
    html = html_response(conn, 200)

    assert html =~ "203.0.113.7"
    refute html =~ "Reverse proxy is not forwarding"
  end

  test "warns when the app only sees the loopback proxy hop", %{conn: conn} do
    conn = admin_dashboard_from(conn, {127, 0, 0, 1})
    html = html_response(conn, 200)

    assert html =~ "127.0.0.1"
    assert html =~ "Reverse proxy is not forwarding"
  end
end
