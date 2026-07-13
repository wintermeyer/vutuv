defmodule VutuvWeb.Admin.ModerationCaseJobTest do
  @moduledoc """
  A job-posting moderation case renders on the admin case page (#934): its
  content-type label exists (the missing clause used to crash the page) and the
  page links straight to the posting.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.JobsHelpers

  alias Vutuv.Moderation

  test "a job-posting case renders its label and a link to the posting", %{conn: conn} do
    posting = publish_job!(nil, %{"title" => "Suspicious role"})
    reporter = insert(:activated_user)

    {:ok, case_record} =
      Moderation.report_content(reporter, posting, %{"category" => "misleading_job"})

    flush_emails()

    {conn, _admin} = create_and_login_admin(conn)
    {:ok, _lv, html} = live(conn, ~p"/admin/moderation/#{case_record.id}")

    assert html =~ "Job posting"
    assert html =~ ~s|href="/jobs/#{posting.slug}"|
  end
end
