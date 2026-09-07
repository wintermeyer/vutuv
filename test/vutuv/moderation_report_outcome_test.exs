defmodule Vutuv.ModerationReportOutcomeTest do
  @moduledoc """
  The decision notice every reporter is owed when their case closes (issue
  #2011): one message per reporter per case, whichever of the four paths closed
  it, naming what happened to the content and who decided.

  Before this, only an owner's *edit* told anybody — an admin upholding or
  rejecting, and the owner deleting, said nothing at all, so a reporter kept
  checking the URL and filed the notice again.
  """

  use Vutuv.DataCase, async: true

  import Ecto.Query

  alias Vutuv.{Activity, Moderation}
  alias Vutuv.Moderation.{Notifier, Report}

  setup do
    owner = insert(:activated_user)
    insert(:email, user: owner)
    admin = insert(:activated_user, admin?: true)
    insert(:email, user: admin)

    {:ok, %{owner: owner, admin: admin}}
  end

  defp member_reporter(attrs \\ []) do
    reporter = insert(:activated_user, attrs)
    insert(:email, user: reporter)
    reporter
  end

  defp report!(reporter, content) do
    {:ok, case_record} =
      Moderation.report_content(reporter, content, %{"category" => "bullying"})

    case_record
  end

  # An outside notice with its address confirmed — the only kind that counts
  # for anything (`Report.effective?/1`).
  defp outside_notice!(content, locale \\ nil) do
    params = %{
      "category" => "copyright",
      "note" => "The photo is mine, the original is at example.com/photo",
      "good_faith?" => "true",
      "reporter_name" => "Rita Holder",
      "reporter_email" => "rita@example.com"
    }

    {:ok, case_record, report, token} = Moderation.file_public_notice(content, params, locale)
    {case_record, report, token}
  end

  # Every email sent so far whose subject is one of the four outcome notices.
  defp outcome_emails do
    for email <- flush_emails(),
        email.subject =~ ~r/report|reported|Meldung|gemeldet/i,
        do: email
  end

  defp subjects(emails), do: Enum.map(emails, & &1.subject)

  defp recipients(emails), do: Enum.flat_map(emails, fn e -> Enum.map(e.to, &elem(&1, 1)) end)

  describe "an admin ruling reaches every reporter once" do
    test "upholding tells the member reporter and the outside notifier", %{
      owner: owner,
      admin: admin
    } do
      post = insert(:post, user: owner)
      reporter = member_reporter()
      case_record = report!(reporter, post)
      {_case, _report, token} = outside_notice!(post)
      {:ok, _state, _report} = Moderation.confirm_public_notice(token)
      flush_emails()

      {:ok, _} = Moderation.uphold_case(Moderation.get_case_with_details(case_record.id), admin)

      emails = outcome_emails()
      addresses = recipients(emails)

      assert Vutuv.Accounts.first_email_value(reporter) in addresses
      assert "rita@example.com" in addresses

      assert Enum.all?(subjects(emails), &(&1 =~ "upheld")),
             "expected the upheld wording, got #{inspect(subjects(emails))}"
    end

    test "rejecting says the report was not upheld", %{owner: owner, admin: admin} do
      post = insert(:post, user: owner)
      reporter = member_reporter()
      case_record = report!(reporter, post)
      flush_emails()

      {:ok, _} = Moderation.reject_case(Moderation.get_case_with_details(case_record.id), admin)

      assert [email] = outcome_emails()
      assert email.subject =~ "not upheld"
    end

    # Calibrated against the claim itself, not against the ruling: a second
    # `uphold_case/2` is already refused by `claim_case_resolution/3`, so that
    # would pass with or without the per-report stamp. This calls the notifier
    # twice by hand — the shape a retry, a second close path or two admins
    # landing at the same instant would produce.
    test "the notice is claimed per report, so a second pass mails nobody", %{
      owner: owner,
      admin: admin
    } do
      post = insert(:post, user: owner)
      reporter = member_reporter()
      case_record = report!(reporter, post)
      flush_emails()

      {:ok, closed} =
        Moderation.uphold_case(Moderation.get_case_with_details(case_record.id), admin)

      assert length(outcome_emails()) == 1

      :ok = Notifier.reporters_case_closed(closed)
      assert outcome_emails() == []
    end

    test "erasing the owner still tells the reporter before the case goes", %{
      owner: owner,
      admin: admin
    } do
      post = insert(:post, user: owner)
      reporter = member_reporter()
      case_record = report!(reporter, post)
      flush_emails()

      {:ok, :deleted} =
        Moderation.remove_owner(Moderation.get_case_with_details(case_record.id), admin, :delete)

      assert [email] = outcome_emails()
      assert email.subject =~ "upheld"
      refute Repo.get(Vutuv.Moderation.Case, case_record.id)
    end
  end

  describe "who is left out" do
    test "an unconfirmed outside notice gets no outcome mail", %{owner: owner, admin: admin} do
      post = insert(:post, user: owner)
      reporter = member_reporter()
      case_record = report!(reporter, post)
      {_case, _report, _token} = outside_notice!(post)
      flush_emails()

      {:ok, _} = Moderation.reject_case(Moderation.get_case_with_details(case_record.id), admin)

      assert "rita@example.com" not in recipients(outcome_emails())
    end

    test "a report marked abusive gets no outcome mail", %{owner: owner, admin: admin} do
      post = insert(:post, user: owner)
      abusive = member_reporter()
      honest = member_reporter()
      case_record = report!(abusive, post)
      _ = report!(honest, post)
      abusive_report = Repo.get_by!(Report, case_id: case_record.id, reporter_id: abusive.id)
      flush_emails()

      {:ok, _} =
        Moderation.reject_case(
          Moderation.get_case_with_details(case_record.id),
          admin,
          [abusive_report.id]
        )

      addresses = recipients(outcome_emails())
      assert Vutuv.Accounts.first_email_value(honest) in addresses
      refute Vutuv.Accounts.first_email_value(abusive) in addresses
    end
  end

  describe "the owner settling it themselves" do
    test "deleting the content tells the reporter it is gone", %{owner: owner} do
      post = insert(:post, user: owner)
      reporter = member_reporter()
      case_record = report!(reporter, post)
      flush_emails()

      :ok =
        Moderation.delete_reported_content(
          Moderation.get_case_with_details(case_record.id),
          owner
        )

      assert [email] = outcome_emails()
      assert email.subject =~ "deleted"
    end

    test "revising it keeps the wording it always had", %{owner: owner} do
      post = insert(:post, user: owner)
      reporter = member_reporter()
      _case = report!(reporter, post)
      flush_emails()

      {:ok, post} = Vutuv.Posts.update_post(post, %{"body" => "a revised body, long enough"})
      Moderation.content_edited(post)

      assert [email] = outcome_emails()
      assert email.subject =~ "revised"
    end
  end

  describe "the in-app entry" do
    test "a member reporter finds the outcome under the bell", %{owner: owner, admin: admin} do
      post = insert(:post, user: owner)
      reporter = member_reporter()
      case_record = report!(reporter, post)

      {:ok, _} = Moderation.uphold_case(Moderation.get_case_with_details(case_record.id), admin)

      %{entries: entries} = Activity.notifications_page(reporter.id, limit: 20)
      outcome = Enum.find(entries, &(&1.kind == "report_outcome"))

      assert outcome, "no report_outcome entry; got #{inspect(Enum.map(entries, & &1.kind))}"
      assert outcome.outcome == "upheld"
      assert Activity.unread_notification_count(reporter.id) > 0
    end

    # The loud half of the nullable-reporter trap: a notice with no user row
    # must be claimed and mailed without anything reaching `Repo.get(User, nil)`
    # or a feed query scoped to a nil id.
    test "an outside notice is claimed without a user row", %{owner: owner, admin: admin} do
      post = insert(:post, user: owner)
      {case_record, _report, token} = outside_notice!(post)
      {:ok, _state, _report} = Moderation.confirm_public_notice(token)

      {:ok, _} = Moderation.uphold_case(Moderation.get_case_with_details(case_record.id), admin)

      report = Repo.one(from(r in Report, where: r.case_id == ^case_record.id))
      assert is_nil(report.reporter_id)
      assert %NaiveDateTime{} = report.outcome_notified_at

      # And it leaves no in-app entry anywhere: the owner's own feed carries
      # their moderation case, never the notifier's ruling.
      %{entries: entries} = Activity.notifications_page(owner.id, limit: 20)
      refute Enum.any?(entries, &(&1.kind == "report_outcome"))
    end
  end

  describe "German" do
    test "a German reporter is answered in German", %{owner: owner, admin: admin} do
      post = insert(:post, user: owner)
      reporter = member_reporter(locale: "de")
      case_record = report!(reporter, post)
      flush_emails()

      {:ok, _} = Moderation.reject_case(Moderation.get_case_with_details(case_record.id), admin)

      assert [email] = outcome_emails()
      assert email.subject =~ "Ihrer Meldung"
      assert email.text_body =~ "Ein Mensch"
      assert email.html_body =~ "Ein Mensch"
    end

    test "an outside notifier is answered in the language they filed in", %{
      owner: owner,
      admin: admin
    } do
      post = insert(:post, user: owner)

      {case_record, _report, token} = outside_notice!(post, "de")
      {:ok, _state, _report} = Moderation.confirm_public_notice(token)
      flush_emails()

      {:ok, _} = Moderation.uphold_case(Moderation.get_case_with_details(case_record.id), admin)

      assert [email] = outcome_emails()
      assert email.subject =~ "Meldung"
      assert email.text_body =~ "Rita Holder"
    end
  end
end
