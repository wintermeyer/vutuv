defmodule VutuvWeb.Admin.ReportControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.BerlinTime

  describe "GET /admin/reports" do
    test "a logged-in non-admin is refused", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      conn = get(conn, ~p"/admin/reports")
      assert html_response(conn, 403)
    end

    test "an admin sees the report, defaulting to yesterday", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      yesterday = Date.add(BerlinTime.today(), -1)

      conn = get(conn, ~p"/admin/reports")
      html = html_response(conn, 200)

      assert html =~ "Daily report"
      assert html =~ ~s(value="#{Date.to_iso8601(yesterday)}")
    end

    test "time-travels to a given ?date and counts that day's activity", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      # A post on the German day 2026-01-15 (winter, +1h: 12:00 UTC is inside).
      insert(:post, inserted_at: ~N[2026-01-15 12:00:00], updated_at: ~N[2026-01-15 12:00:00])

      conn = get(conn, ~p"/admin/reports?#{%{date: "2026-01-15"}}")
      html = html_response(conn, 200)

      assert html =~ ~s(value="2026-01-15")
      assert html =~ "Posts"
      refute html =~ "No activity on this day."
    end

    test "a future ?date is clamped to today", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      today = BerlinTime.today()
      future = today |> Date.add(30) |> Date.to_iso8601()

      conn = get(conn, ~p"/admin/reports?#{%{date: future}}")
      html = html_response(conn, 200)

      assert html =~ ~s(value="#{Date.to_iso8601(today)}")
      # No "next day" link when already on today (nothing newer to show).
      refute html =~ ~s(id="report-next-day")
    end

    test "a malformed ?date falls back to yesterday instead of erroring", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      yesterday = Date.add(BerlinTime.today(), -1)

      conn = get(conn, ~p"/admin/reports?#{%{date: "not-a-date"}}")
      html = html_response(conn, 200)

      assert html =~ ~s(value="#{Date.to_iso8601(yesterday)}")
    end

    test "renders the German labels for a de viewer", %{conn: conn} do
      # The daily-report strings were added to the source but never extracted
      # into the .po files, so a de operator saw English labels. Guard the
      # German translations now that they exist.
      {conn, _admin} = create_and_login_admin(conn)

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de")
        |> get(~p"/admin/reports")
        |> html_response(200)

      assert html =~ "Tagesbericht"
      assert html =~ "Vorheriger Tag"
      assert html =~ "Kennzahl"
      assert html =~ "Anzahl"
      assert html =~ "Neue bestätigte Registrierungen (per PIN)"
    end
  end
end
