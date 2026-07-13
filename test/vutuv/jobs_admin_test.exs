defmodule Vutuv.JobsAdminTest do
  @moduledoc """
  The `/admin/jobs` context functions (issue #934): overview counts, the
  filtered / searched / report-narrowed admin list, the detail payload (poster
  footprint incl. the cold-outreach counter and report history) and the admin
  freeze / close actions.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory
  import Vutuv.JobsHelpers

  alias Vutuv.{Chat, Jobs, Moderation}
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Organizations.Organization

  # A trusted reporter freezes the posting and opens a pending_owner case.
  defp report_posting!(posting) do
    reporter = insert(:activated_user)

    {:ok, case_record} =
      Moderation.report_content(reporter, posting, %{"category" => "misleading_job"})

    case_record
  end

  defp set_expiry!(posting, %Date{} = date) do
    Repo.update_all(from(p in JobPosting, where: p.id == ^posting.id), set: [expires_on: date])
  end

  describe "admin_overview_counts/0" do
    test "counts live, expiring, frozen postings and open cases" do
      poster = poster_fixture()
      _live = publish_job!(poster, %{"title" => "Live role"})
      expiring = publish_job!(poster, %{"title" => "Expiring role"})
      set_expiry!(expiring, Date.add(Vutuv.BerlinTime.today(), 3))

      frozen = publish_job!(poster, %{"title" => "Bad role"})
      report_posting!(frozen)

      counts = Jobs.admin_overview_counts()
      assert counts.published == 2
      assert counts.expiring == 1
      assert counts.frozen == 1
      assert counts.open_cases == 1
    end
  end

  describe "admin_jobs_page/1 filters" do
    test "status filter separates live and frozen postings" do
      poster = poster_fixture()
      live = publish_job!(poster, %{"title" => "Live role"})
      bad = publish_job!(poster, %{"title" => "Bad role"})
      report_posting!(bad)

      published_ids = Enum.map(Jobs.admin_jobs_page(status: "published").entries, & &1.id)
      assert live.id in published_ids
      refute bad.id in published_ids

      frozen_ids = Enum.map(Jobs.admin_jobs_page(status: "frozen").entries, & &1.id)
      assert bad.id in frozen_ids
      refute live.id in frozen_ids
    end

    test "the has-open-report filter returns only reported postings" do
      poster = poster_fixture()
      clean = publish_job!(poster, %{"title" => "Clean role"})
      bad = publish_job!(poster, %{"title" => "Bad role"})
      report_posting!(bad)

      reported_ids = Enum.map(Jobs.admin_jobs_page(report: "open").entries, & &1.id)
      assert bad.id in reported_ids
      refute clean.id in reported_ids
    end

    test "search matches title, poster @handle and organization name" do
      poster = poster_fixture(username: "recruiterjane")
      other = poster_fixture(username: "someoneelse")

      org =
        Repo.insert!(%Organization{
          name: "Acme Widgets GmbH",
          kind: :company,
          slug: "acme-widgets",
          city: "Berlin",
          country: "DE",
          status: "active",
          created_by_user_id: poster.id
        })

      by_title = publish_job!(poster, %{"title" => "Unicorn Wrangler"})
      by_org = publish_job!(poster, %{"title" => "Ordinary role"})

      Repo.update_all(from(p in JobPosting, where: p.id == ^by_org.id),
        set: [organization_id: org.id]
      )

      _by_other = publish_job!(other, %{"title" => "Ordinary role"})

      # Case-insensitive title match.
      assert by_title.id in ids(Jobs.admin_jobs_page(search: "unicorn"))
      assert by_org.id in ids(Jobs.admin_jobs_page(search: "acme widgets"))

      handle_ids = ids(Jobs.admin_jobs_page(search: "recruiterjane"))
      assert by_title.id in handle_ids
      assert by_org.id in handle_ids
    end
  end

  describe "admin_job_detail/1" do
    test "carries the poster footprint (incl. cold-outreach counter) and report history" do
      poster = poster_fixture()
      posting = publish_job!(poster, %{"title" => "A role"})
      report_posting!(posting)

      # A cold-outreach request the poster opened, so the counter is non-zero.
      Chat.find_or_create_conversation(poster, insert(:activated_user))

      detail = Jobs.admin_job_detail(posting.id)

      assert detail.posting.id == posting.id
      assert detail.footprint.total == 1
      assert detail.footprint.open_cases == 1
      assert detail.footprint.cold_outreach == 1
      assert [_case] = detail.cases
    end

    test "returns nil for a bogus id" do
      assert Jobs.admin_job_detail("not-a-uuid") == nil
    end
  end

  describe "admin freeze / unfreeze / close" do
    test "freeze hides the posting; unfreeze restores it" do
      posting = publish_job!()

      {:ok, frozen} = Jobs.admin_set_frozen(posting, true)
      assert frozen.frozen_at
      refute Jobs.visible_to?(frozen, nil)

      {:ok, thawed} = Jobs.admin_set_frozen(frozen, false)
      refute thawed.frozen_at
      assert Jobs.visible_to?(thawed, nil)
    end

    test "close ends a live posting with the moderation reason" do
      posting = publish_job!()

      {:ok, closed} = Jobs.admin_close(posting)
      assert closed.status == :closed
      assert closed.close_reason == :moderation
      assert closed.closed_at
    end
  end

  defp ids(%{entries: entries}), do: Enum.map(entries, & &1.id)
end
