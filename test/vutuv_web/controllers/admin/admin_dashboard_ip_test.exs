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

  # On a phone the live figures are what an admin opens the page for, so a
  # healthy IP line waits at the foot of the page. A broken proxy is work to do
  # and keeps its place above everything.
  test "a healthy IP line sits at the end of the page", %{conn: conn} do
    html = html_response(admin_dashboard_from(conn, {203, 0, 113, 7}), 200)
    {ip_at, _} = :binary.match(html, "admin-client-ip")
    {last_card_at, _} = :binary.match(html, "admin-legal-link")

    assert ip_at > last_card_at
  end

  test "the proxy warning keeps the top of the page", %{conn: conn} do
    html = html_response(admin_dashboard_from(conn, {127, 0, 0, 1}), 200)
    {warning_at, _} = :binary.match(html, "admin-proxy-ip-warning")
    {dashboard_at, _} = :binary.match(html, "admin-live-dashboard")

    assert warning_at < dashboard_at
    refute html =~ "admin-client-ip"
  end

  test "the page no longer opens with the tagline", %{conn: conn} do
    html = html_response(admin_dashboard_from(conn, {203, 0, 113, 7}), 200)

    refute html =~ "Everything that keeps vutuv running"
  end
end
