defmodule VutuvWeb.Admin.JobLiveTest do
  @moduledoc """
  The `/admin/jobs` oversight dashboard (issue #934): the tiles, the filtered
  list, the per-posting detail drawer (poster footprint + report history) and
  the freeze / unfreeze / close / delete actions, all reload-free.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.JobsHelpers

  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Moderation

  defp report_posting!(posting) do
    reporter = insert(:activated_user)

    {:ok, case_record} =
      Moderation.report_content(reporter, posting, %{"category" => "misleading_job"})

    flush_emails()
    case_record
  end

  describe "authorization" do
    test "non-admins are locked out", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/jobs"), 403)
    end
  end

  describe "list" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "shows the tiles and a posting row linking to its detail", %{conn: conn} do
      posting = publish_job!(nil, %{"title" => "Senior Gopher (m/w/d)"})

      {:ok, lv, html} = live(conn, ~p"/admin/jobs")

      assert html =~ "Live"
      assert html =~ "Senior Gopher"
      assert has_element?(lv, "#job-row-#{posting.id}")
    end

    test "the has-open-report filter narrows to reported postings", %{conn: conn} do
      clean = publish_job!(nil, %{"title" => "Clean role"})
      bad = publish_job!(nil, %{"title" => "Shady role"})
      report_posting!(bad)

      {:ok, lv, _html} = live(conn, ~p"/admin/jobs")
      lv |> element("#filter-reported") |> render_click()

      assert has_element?(lv, "#job-row-#{bad.id}")
      refute has_element?(lv, "#job-row-#{clean.id}")
    end
  end

  describe "detail drawer" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "shows the poster footprint and report history", %{conn: conn} do
      poster = poster_fixture(username: "hiringhal")
      posting = publish_job!(poster, %{"title" => "A role"})
      case_record = report_posting!(posting)

      {:ok, _lv, html} = live(conn, ~p"/admin/jobs?selected=#{posting.id}")

      assert html =~ "Poster footprint"
      assert html =~ "Cold outreach"
      assert html =~ "Report history"
      assert html =~ "@hiringhal"
      assert html =~ "/admin/moderation/#{case_record.id}"
    end

    test "renders in German without an interpolation crash", %{conn: conn} do
      poster = poster_fixture()
      posting = publish_job!(poster, %{"title" => "Eine Stelle"})
      report_posting!(posting)

      # The dead render goes through the locale plug; a 200 (not a 500) proves the
      # interpolated counter/footprint strings didn't crash, and the German words
      # prove it is the German render, not an English fallback masking a bug.
      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> get(~p"/admin/jobs?selected=#{posting.id}")
        |> html_response(200)

      assert html =~ "Stellenanzeigen"
      assert html =~ "Kaltakquise"
      assert html =~ "Bewerbungsklicks"
    end
  end

  describe "actions" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "freeze then unfreeze acts reload-free", %{conn: conn} do
      posting = publish_job!()

      {:ok, lv, _html} = live(conn, ~p"/admin/jobs?selected=#{posting.id}")

      lv |> element("#job-detail button[phx-click=freeze]") |> render_click()
      assert Repo.get!(JobPosting, posting.id).frozen_at
      assert has_element?(lv, "#job-detail button[phx-click=unfreeze]")

      lv |> element("#job-detail button[phx-click=unfreeze]") |> render_click()
      refute Repo.get!(JobPosting, posting.id).frozen_at
    end

    test "close ends the posting with the moderation reason", %{conn: conn} do
      posting = publish_job!()

      {:ok, lv, _html} = live(conn, ~p"/admin/jobs?selected=#{posting.id}")
      lv |> element("#job-detail button[phx-click=close-posting]") |> render_click()

      closed = Repo.get!(JobPosting, posting.id)
      assert closed.status == :closed
      assert closed.close_reason == :moderation
    end

    test "delete removes the posting", %{conn: conn} do
      posting = publish_job!()

      {:ok, lv, _html} = live(conn, ~p"/admin/jobs?selected=#{posting.id}")
      lv |> element("#job-detail button[phx-click=delete]") |> render_click()

      refute Repo.get(JobPosting, posting.id)
    end
  end
end
