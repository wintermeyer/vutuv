defmodule VutuvWeb.Admin.ModerationOutsideReporterTest do
  @moduledoc """
  The two admin surfaces that name who filed a report, rendered with a report
  that has **no reporter account** (issue #2009).

  This is the loudest shape of the nullable-`reporter_id` trap and the one a
  context test cannot reach: the case page used to look its stats up by a nil
  key (`KeyError`) and build a profile path out of a nil reporter (`cannot
  convert nil to param`), and the track-record page's inner join to `users`
  dropped every outside notice from the one screen whose job is showing who
  abuses the report button. Both are 500s or silent omissions that only a
  render can catch.
  """

  use VutuvWeb.ConnCase

  alias Vutuv.Moderation
  alias Vutuv.Moderation.{Case, Report}

  setup %{conn: conn} do
    {admin_conn, _admin} = create_and_login_admin(conn)
    owner = insert_activated_user()
    post = insert(:post, user: owner)

    {:ok, %{conn: admin_conn, owner: owner, post: post}}
  end

  defp notice(attrs \\ %{}) do
    Map.merge(
      %{
        "category" => "copyright",
        "note" => "That photograph is mine.",
        "good_faith?" => "true",
        "reporter_name" => "Rita Holder",
        "reporter_email" => "rita@example.com"
      },
      attrs
    )
  end

  defp file!(content, attrs \\ %{}) do
    {:ok, case_record, _report, token} = Moderation.file_public_notice(content, notice(attrs))
    {case_record, token}
  end

  describe "the case page" do
    test "renders a notice whose address is not confirmed yet", %{conn: conn, post: post} do
      {case_record, _token} = file!(post)

      html = conn |> get(~p"/admin/moderation/#{case_record.id}") |> html_response(200)

      assert html =~ "Rita Holder"
      assert html =~ "rita@example.com"
      # An admin ruling on a notice nobody stood behind has to see that.
      assert html =~ "address not confirmed"
      # And the abusive checkbox may not promise a strike on an account that
      # does not exist.
      assert html =~ "that address loses our trust"
      refute html =~ "was a deliberate weapon (strikes the reporter)"
    end

    # The notice was quoted with a German opening mark and an ASCII closing
    # one, hardcoded, on a page that renders in three languages (issue #2068).
    # The quotes are the translation's now, like everywhere else in the app.
    test "quotes the notice with the marks the reader's language uses", %{conn: conn, post: post} do
      {case_record, _token} = file!(post)

      assert conn |> get(~p"/admin/moderation/#{case_record.id}") |> html_response(200) =~
               "“That photograph is mine.”"

      assert conn
             |> recycle()
             |> put_req_header("accept-language", "de-DE,de")
             |> get(~p"/admin/moderation/#{case_record.id}")
             |> html_response(200) =~ "„That photograph is mine.“"
    end

    test "renders a confirmed notice beside a member's own report", %{
      conn: conn,
      post: post
    } do
      member = insert_activated_user()
      {:ok, _case_record} = Moderation.report_content(member, post, %{"category" => "spam"})

      {case_record, token} = file!(post)
      {:ok, :confirmed, _report} = Moderation.confirm_public_notice(token)

      html = conn |> get(~p"/admin/moderation/#{case_record.id}") |> html_response(200)

      assert html =~ "@#{member.username}"
      assert html =~ "rita@example.com"
      refute html =~ "address not confirmed"
    end

    test "the queue lists the case", %{conn: conn, post: post} do
      {case_record, _token} = file!(post)

      html = conn |> get(~p"/admin/moderation") |> html_response(200)
      assert html =~ case_record.id
    end
  end

  describe "the reporter track records" do
    test "list an outside notifier by the address they confirmed", %{conn: conn, post: post} do
      {_case_record, token} = file!(post)
      {:ok, :confirmed, _report} = Moderation.confirm_public_notice(token)

      html = conn |> get(~p"/admin/moderation/reporters") |> html_response(200)
      assert html =~ "rita@example.com"
    end

    test "leave out a notice nobody confirmed", %{conn: conn, post: post} do
      {_case_record, _token} = file!(post, %{"reporter_email" => "unconfirmed@example.com"})

      html = conn |> get(~p"/admin/moderation/reporters") |> html_response(200)
      refute html =~ "unconfirmed@example.com"
    end
  end

  describe "rejecting a case" do
    test "marks an outside notice abusive without striking a missing account", %{
      conn: conn,
      post: post
    } do
      {case_record, token} = file!(post)
      {:ok, :confirmed, _report} = Moderation.confirm_public_notice(token)
      report = Repo.get_by!(Report, case_id: case_record.id)

      conn =
        post(conn, ~p"/admin/moderation/#{case_record.id}/reject", %{
          "abusive_report_ids" => [report.id]
        })

      assert redirected_to(conn) == ~p"/admin/moderation"
      assert Repo.get!(Report, report.id).abusive?
      assert Repo.get!(Case, case_record.id).status == "rejected"
      assert is_nil(Repo.get!(Vutuv.Posts.Post, post.id).frozen_at)
    end
  end
end
