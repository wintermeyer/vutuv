defmodule Vutuv.ModerationPageOwnerNoticeTest do
  @moduledoc """
  Who hears that a report hid something a **page** published (issue #2120).

  #2089 shipped the narrow answer: a moderation case carries one `users` row,
  so the mail and the derived in-app feed both went to `accountable_user_id/1`
  — the member who claimed the page — and a page run by a team could lose a
  press photo without the people who put it there ever hearing about it.

  What is held here is the wider one: every **owner** of the page is told, in
  the app and by mail, and nobody else is — a publisher may write the Media Kit
  and a recruiter may look at it, and neither of them answers for the page.
  Accountability does not move: the claimer still carries the case and is still
  the only member who can settle it.

  Not async: the freeze moves files on disk.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.ImageHelpers, only: [put_press_picture: 1]
  import Vutuv.OrganizationsHelpers, only: [active_organization: 0]
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Accounts
  alias Vutuv.Activity
  alias Vutuv.Moderation
  alias Vutuv.Organizations

  @copyright %{"category" => "copyright", "note" => "Mein Foto.", "good_faith?" => "true"}

  setup do
    # A page is claimed through the DNS check, which the test env leaves off.
    put_config(:verify_organization_domains, true)

    {organization, claimer} = active_organization()
    insert(:email, user: claimer)

    reporter = insert(:activated_user)

    {:ok, organization: organization, claimer: claimer, reporter: reporter}
  end

  defp team_member(organization, claimer, role) do
    user = insert(:activated_user)
    insert(:email, user: user)
    {:ok, _} = Organizations.add_role(organization, user, role, claimer)
    user
  end

  defp addressed_to(emails, user) do
    address = Accounts.first_email_value(user)
    Enum.filter(emails, &match?([{_name, ^address}], &1.to))
  end

  defp moderation_entries(user) do
    %{entries: entries} = Activity.notifications_page(user.id)
    Enum.filter(entries, &(&1.kind == "moderation"))
  end

  describe "a picture a page published" do
    test "reaches every owner of the page, and nobody else on its team", context do
      %{organization: organization, claimer: claimer, reporter: reporter} = context

      co_owner = team_member(organization, claimer, "owner")
      publisher = team_member(organization, claimer, "publisher")
      recruiter = team_member(organization, claimer, "recruiter")
      image = put_press_picture(organization)
      flush_emails()

      assert {:ok, case_record} = Moderation.report_content(reporter, image, @copyright)
      # The strike ladder does not move: the claimer still carries the case.
      assert case_record.owner_id == claimer.id

      emails = flush_emails()
      assert [_] = addressed_to(emails, claimer)
      assert [_] = addressed_to(emails, co_owner)
      assert addressed_to(emails, publisher) == []
      assert addressed_to(emails, recruiter) == []

      assert [_] = moderation_entries(co_owner)
      assert moderation_entries(publisher) == []
      assert moderation_entries(recruiter) == []
    end

    test "tells the co-owner what was claimed and where the case is", context do
      %{organization: organization, claimer: claimer, reporter: reporter} = context

      co_owner = team_member(organization, claimer, "owner")
      image = put_press_picture(organization)
      flush_emails()

      assert {:ok, case_record} = Moderation.report_content(reporter, image, @copyright)

      assert [email] = addressed_to(flush_emails(), co_owner)
      # The page it is about, the ground it was reported on, and the case page.
      assert email.text_body =~ organization.name
      assert email.text_body =~ "moderation/cases/#{case_record.id}"
      assert email.html_body =~ organization.name
      # It must not promise a co-owner the self-service round: only the member
      # who carries the case can dispute or delete.
      refute email.subject =~ "Your content"
    end

    # vutuv is a German site, and a brand-new msgid is exactly what
    # `gettext.extract --merge` fuzzy-fills with somebody else's sentence: the
    # three the page notice added came back translated in the *member's* voice
    # ("Eine Meldung zu Ihrem Inhalt"), which drops the page's name and tells a
    # co-owner their own content was reported. So the German is asserted by name.
    test "and says it in German to a German owner", context do
      %{organization: organization, claimer: claimer, reporter: reporter} = context

      co_owner = team_member(organization, claimer, "owner")
      co_owner |> Ecto.Changeset.change(locale: "de") |> Repo.update!()
      image = put_press_picture(organization)
      flush_emails()

      assert {:ok, _case} = Moderation.report_content(reporter, image, @copyright)

      assert [email] = addressed_to(flush_emails(), Repo.reload!(co_owner))

      assert email.subject ==
               "Ein Inhalt von #{organization.name} wurde gemeldet und ist verborgen"

      assert email.text_body =~ "ein Bild von #{organization.name} auf vutuv wurde gemeldet."
      assert email.text_body =~ "Sie erfahren davon, weil Ihnen #{organization.name} gehört."
      assert email.text_body =~ "Auf die Meldung antworten kann nur das Mitglied"
      refute email.text_body =~ "eines Ihrer Bilder"
    end

    # The badge is its own arm of the feed (`count_moderation/2`), so it is
    # widened separately from the list and asserted separately. As a delta:
    # being made an owner is itself a notification, so the co-owner starts at 1.
    test "counts toward the co-owner's unread notifications", context do
      %{organization: organization, claimer: claimer, reporter: reporter} = context

      co_owner = team_member(organization, claimer, "owner")
      image = put_press_picture(organization)
      before = Activity.unread_notification_count(co_owner)

      assert {:ok, _case} = Moderation.report_content(reporter, image, @copyright)

      assert Activity.unread_notification_count(Repo.reload!(co_owner)) == before + 1
    end

    # The calibration for the widened feed query: it reads
    # `owner_id == me OR the case is about a page I own`, and a NULL
    # `organization_id` on the left of an `IN` answers NULL, never true. A
    # member's own case must therefore stay invisible to every page owner who
    # has nothing to do with it.
    test "a member's own case stays out of an unrelated page owner's feed", context do
      %{organization: organization, claimer: claimer, reporter: reporter} = context

      co_owner = team_member(organization, claimer, "owner")
      stranger = insert(:activated_user)
      insert(:email, user: stranger)
      image = put_press_picture(stranger)

      assert {:ok, _case} = Moderation.report_content(reporter, image, @copyright)

      assert [_] = moderation_entries(stranger)
      assert moderation_entries(co_owner) == []
      assert moderation_entries(claimer) == []
    end
  end

  describe "what a page owner may do with the case" do
    setup context do
      co_owner = team_member(context.organization, context.claimer, "owner")
      image = put_press_picture(context.organization)

      {:ok, case_record} = Moderation.report_content(context.reporter, image, @copyright)

      {:ok, co_owner: co_owner, case_record: case_record}
    end

    test "read it", %{case_record: case_record, co_owner: co_owner} do
      assert Moderation.case_readable_by?(case_record, co_owner)
    end

    test "but not settle it — that stays with the member who carries it", context do
      %{case_record: case_record, co_owner: co_owner, claimer: claimer} = context

      assert {:error, :not_allowed} = Moderation.dispute_case(case_record, co_owner)
      assert {:error, :not_allowed} = Moderation.delete_reported_content(case_record, co_owner)

      assert {:ok, _} = Moderation.dispute_case(case_record, claimer)
    end

    test "and a publisher may not even read it", context do
      %{case_record: case_record, organization: organization, claimer: claimer} = context

      publisher = team_member(organization, claimer, "publisher")

      refute Moderation.case_readable_by?(case_record, publisher)
    end
  end
end
