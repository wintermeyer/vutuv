defmodule VutuvWeb.Admin.ModerationLiveTest do
  @moduledoc """
  The admin moderation queue + case detail as LiveViews. The queue
  (`/admin/moderation`) lists open cases; the case page (`/admin/moderation/:id`)
  reviews the evidence and rules on it. Upholding/rejecting acts reload-free over
  the socket and drops back to the queue. The classic CSRF POST routes
  (`ModerationController.uphold/reject`) stay as the no-JS / scriptable fallback
  and are covered by `ModerationControllerTest`.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Moderation
  alias Vutuv.Moderation.{Case, Report, Strike}

  defp escalated_case do
    owner = insert_activated_user()
    insert(:email, user: owner)
    post = insert(:post, user: owner)
    reporter = insert(:activated_user)
    {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})
    {:ok, case_record} = Moderation.dispute_case(case_record, owner)
    flush_emails()
    {case_record, post, owner, reporter}
  end

  describe "authorization" do
    test "non-admins are locked out of the queue", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/moderation"), 403)
    end
  end

  describe "queue" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "lists open cases and links to each", %{conn: conn} do
      {case_record, _post, _owner, _reporter} = escalated_case()

      {:ok, lv, html} = live(conn, ~p"/admin/moderation")

      assert html =~ "Escalated"
      assert has_element?(lv, "#case-row-#{case_record.id}")
      assert has_element?(lv, ~s|a[href="/admin/moderation/#{case_record.id}"]|)
    end
  end

  describe "case detail" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "shows the reported content, reporter track record and timeline", %{conn: conn} do
      {case_record, post, _owner, _reporter} = escalated_case()

      {:ok, _lv, html} = live(conn, ~p"/admin/moderation/#{case_record.id}")

      assert html =~ post.body
      assert html =~ "1 report so far"
      assert html =~ "case-timeline"
      assert html =~ "Report filed"
    end

    test "uphold strikes the owner and drops back to the queue, no reload", %{conn: conn} do
      {case_record, post, owner, _reporter} = escalated_case()

      {:ok, lv, _html} = live(conn, ~p"/admin/moderation/#{case_record.id}")
      lv |> element("#uphold-case") |> render_click()

      assert_redirect(lv, ~p"/admin/moderation")
      assert Repo.get!(Case, case_record.id).status == "upheld"
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
      assert [%Strike{role: "owner"}] = Repo.all(Strike.where_user(owner.id))
    end

    test "reject unfreezes the content and drops back to the queue, no reload", %{conn: conn} do
      {case_record, post, _owner, _reporter} = escalated_case()

      {:ok, lv, _html} = live(conn, ~p"/admin/moderation/#{case_record.id}")
      lv |> form("#reject-form") |> render_submit()

      assert_redirect(lv, ~p"/admin/moderation")
      assert Repo.get!(Case, case_record.id).status == "rejected"
      refute Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end

    test "reject can mark a report abusive and strike its reporter", %{conn: conn} do
      {case_record, _post, _owner, reporter} = escalated_case()
      report = Repo.get_by!(Report, case_id: case_record.id)

      {:ok, lv, _html} = live(conn, ~p"/admin/moderation/#{case_record.id}")

      lv
      |> form("#reject-form", %{"abusive_report_ids" => [report.id]})
      |> render_submit()

      assert_redirect(lv, ~p"/admin/moderation")
      assert Repo.get!(Report, report.id).abusive?
      assert [%Strike{role: "reporter"}] = Repo.all(Strike.where_user(reporter.id))
    end
  end
end
