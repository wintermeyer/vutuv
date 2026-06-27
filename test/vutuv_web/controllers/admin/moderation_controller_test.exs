defmodule VutuvWeb.Admin.ModerationControllerTest do
  @moduledoc """
  The classic moderation routes: the private evidence stream, the read-only
  reporter dashboard, and the uphold/reject POSTs that are the no-JS fallback for
  the case page's reload-free rulings. The queue + case rendering and the
  reload-free path live in `ModerationLiveTest`.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Moderation
  alias Vutuv.Moderation.{Case, Report, Strike}

  defp escalated_case do
    owner = insert_activated_user()
    insert(:email, user: owner)
    post = insert(:post, user: owner)
    reporter = insert(:activated_user)
    {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})
    {:ok, case_record} = Moderation.dispute_case(case_record, owner)
    # Drain the owner-notification email so login_via_pin reads its own PIN
    # mail, not the moderation notice.
    flush_emails()
    {case_record, post, owner, reporter}
  end

  describe "authorization" do
    test "non-admins are locked out of a classic route", %{conn: conn} do
      {case_record, _post, _owner, _reporter} = escalated_case()
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/moderation/#{case_record.id}/evidence"), 403)
    end
  end

  describe "evidence" do
    test "404s while no screenshot was captured", %{conn: conn} do
      {case_record, _post, _owner, _reporter} = escalated_case()
      {conn, _admin} = create_and_login_admin(conn)

      assert conn
             |> get(~p"/admin/moderation/#{case_record.id}/evidence")
             |> html_response(404)
    end

    test "streams the stored screenshot to admins", %{conn: conn} do
      {case_record, _post, _owner, _reporter} = escalated_case()

      filename = "#{case_record.id}.webp"
      path = Moderation.EvidenceScreenshot.path(filename)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not really a webp")
      on_exit(fn -> File.rm(path) end)

      Repo.update!(Ecto.Changeset.change(case_record, evidence_screenshot: filename))

      {conn, _admin} = create_and_login_admin(conn)
      conn = get(conn, ~p"/admin/moderation/#{case_record.id}/evidence")

      assert response(conn, 200) == "not really a webp"
      assert response_content_type(conn, :webp) =~ "image/webp"
    end
  end

  describe "uphold" do
    test "strikes the owner and keeps the content frozen", %{conn: conn} do
      {case_record, post, owner, _reporter} = escalated_case()
      {conn, _admin} = create_and_login_admin(conn)

      conn = post(conn, ~p"/admin/moderation/#{case_record.id}/uphold")

      assert redirected_to(conn) == ~p"/admin/moderation"
      assert Repo.get!(Case, case_record.id).status == "upheld"
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
      assert [%Strike{role: "owner"}] = Repo.all(Strike.where_user(owner.id))
    end
  end

  describe "reject" do
    test "unfreezes the content", %{conn: conn} do
      {case_record, post, _owner, _reporter} = escalated_case()
      {conn, _admin} = create_and_login_admin(conn)

      conn = post(conn, ~p"/admin/moderation/#{case_record.id}/reject")

      assert redirected_to(conn) == ~p"/admin/moderation"
      assert Repo.get!(Case, case_record.id).status == "rejected"
      refute Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end

    test "marks chosen reports abusive and strikes their reporters", %{conn: conn} do
      {case_record, _post, _owner, reporter} = escalated_case()
      report = Repo.get_by!(Report, case_id: case_record.id)
      {conn, _admin} = create_and_login_admin(conn)

      conn =
        post(conn, ~p"/admin/moderation/#{case_record.id}/reject", %{
          "abusive_report_ids" => [report.id]
        })

      assert redirected_to(conn) == ~p"/admin/moderation"
      assert Repo.get!(Report, report.id).abusive?
      assert [%Strike{role: "reporter"}] = Repo.all(Strike.where_user(reporter.id))
    end
  end

  describe "reporters dashboard" do
    test "lists reporters with their track record", %{conn: conn} do
      {case_record, _post, _owner, reporter} = escalated_case()
      {conn, admin} = create_and_login_admin(conn)
      {:ok, _} = Moderation.reject_case(case_record, admin)

      conn = get(conn, ~p"/admin/moderation/reporters")
      response = html_response(conn, 200)
      assert response =~ reporter.username
    end
  end
end
