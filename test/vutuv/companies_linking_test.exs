defmodule Vutuv.CompaniesLinkingTest do
  @moduledoc """
  Linking a work experience to a verified company page (issue #931): the
  editor's suggestion match, the canonical link path, the changeset guard that
  only ever links to a **verified** company, and the company page's People
  section (which member appears, in which order, under the directory privacy
  gate).
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Companies
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo

  describe "canonical_path/1" do
    test "a handle-less company lives at /companies/:slug" do
      company = insert(:company, slug: "acme-gmbh", username: nil)
      assert Companies.canonical_path(company) == "/companies/acme-gmbh"
    end

    test "a company with a root handle is canonical at /:handle" do
      company = insert(:company, slug: "acme-gmbh", username: "acme")
      assert Companies.canonical_path(company) == "/acme"
    end
  end

  describe "suggest_company_for_org/1" do
    test "matches a verified company's name case-insensitively" do
      company = insert(:company, name: "ACME GmbH")
      assert %{id: id} = Companies.suggest_company_for_org("acme gmbh")
      assert id == company.id
    end

    test "matches an alias case-insensitively" do
      company = insert(:company, name: "Acme GmbH")
      {:ok, _} = Companies.add_alias(company, "ACME Deutschland", "brand")

      assert %{id: id} = Companies.suggest_company_for_org("acme deutschland")
      assert id == company.id
    end

    test "requires the whole name to match (no substring)" do
      insert(:company, name: "Acme Foundation")
      assert Companies.suggest_company_for_org("Acme") == nil
    end

    test "never suggests a pending or frozen company" do
      insert(:company, name: "Pending Co", status: "pending", verified_at: nil)

      insert(:company,
        name: "Frozen Co",
        frozen_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
      )

      assert Companies.suggest_company_for_org("Pending Co") == nil
      assert Companies.suggest_company_for_org("Frozen Co") == nil
    end

    test "returns nil for a blank or too-short term" do
      assert Companies.suggest_company_for_org("") == nil
      assert Companies.suggest_company_for_org("a") == nil
      assert Companies.suggest_company_for_org(nil) == nil
    end
  end

  describe "the work-experience link guard" do
    setup do
      %{user: insert(:activated_user)}
    end

    test "links to an active company", %{user: user} do
      company = insert(:company)

      changeset =
        WorkExperience.changeset(%WorkExperience{user_id: user.id}, %{
          "title" => "Engineer",
          "organization" => "Acme",
          "company_id" => company.id
        })

      assert {:ok, work} = Repo.insert(changeset)
      assert work.company_id == company.id
    end

    test "silently drops a link to a frozen company (free text stays)", %{user: user} do
      frozen =
        insert(:company,
          frozen_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
        )

      changeset =
        WorkExperience.changeset(%WorkExperience{user_id: user.id}, %{
          "title" => "Engineer",
          "organization" => "Acme",
          "company_id" => frozen.id
        })

      assert {:ok, work} = Repo.insert(changeset)
      assert is_nil(work.company_id)
    end

    test "unlinking sets company_id back to nil", %{user: user} do
      company = insert(:company)
      work = insert(:work_experience, user: user, company: company)

      changeset = WorkExperience.changeset(work, %{"company_id" => ""})
      assert {:ok, updated} = Repo.update(changeset)
      assert is_nil(updated.company_id)
    end
  end

  describe "company_people_page/2 and company_people_count/1" do
    setup do
      company = insert(:company)
      %{company: company}
    end

    test "lists a linked member with their written title", %{company: company} do
      user = insert(:activated_user, first_name: "Cara", last_name: "Current")

      insert(:work_experience,
        user: user,
        company: company,
        title: "Chief Bridge Engineer",
        end_year: nil
      )

      assert Companies.company_people_count(company) == 1
      assert %{entries: [entry], more?: false} = Companies.company_people_page(company)
      assert entry.user.id == user.id
      assert entry.title == "Chief Bridge Engineer"
      assert entry.current?
    end

    test "current members lead past members", %{company: company} do
      past = insert(:activated_user, first_name: "Aaron", last_name: "Alumni")

      insert(:work_experience,
        user: past,
        company: company,
        title: "Former Dev",
        start_year: 2015,
        end_year: 2019
      )

      current = insert(:activated_user, first_name: "Zoe", last_name: "Zurzeit")

      insert(:work_experience,
        user: current,
        company: company,
        title: "Current Dev",
        end_year: nil
      )

      assert %{entries: [first, second]} = Companies.company_people_page(company)
      assert first.user.id == current.id
      assert first.current?
      assert second.user.id == past.id
      refute second.current?
    end

    test "respects the directory privacy gate", %{company: company} do
      hidden = insert(:activated_user, noindex?: true)
      insert(:work_experience, user: hidden, company: company, title: "Hidden", end_year: nil)

      unconfirmed = insert(:user, email_confirmed?: false)

      insert(:work_experience,
        user: unconfirmed,
        company: company,
        title: "Unconfirmed",
        end_year: nil
      )

      assert Companies.company_people_count(company) == 0
      assert %{entries: []} = Companies.company_people_page(company)
    end

    test "collapses a member's several roles into one entry, newest current title", %{
      company: company
    } do
      user = insert(:activated_user)

      insert(:work_experience,
        user: user,
        company: company,
        title: "Junior Dev",
        start_year: 2018,
        end_year: 2020
      )

      insert(:work_experience,
        user: user,
        company: company,
        title: "Senior Dev",
        start_year: 2020,
        end_year: nil
      )

      assert %{entries: [entry]} = Companies.company_people_page(company)
      assert entry.title == "Senior Dev"
      assert entry.current?
    end

    test "paginates with more?/next_offset", %{company: company} do
      for i <- 1..3 do
        user = insert(:activated_user, last_name: "Member#{i}")
        insert(:work_experience, user: user, company: company, title: "Dev", end_year: nil)
      end

      assert %{entries: entries, more?: true, next_offset: 2} =
               Companies.company_people_page(company, limit: 2)

      assert length(entries) == 2

      assert %{entries: rest, more?: false} =
               Companies.company_people_page(company, limit: 2, offset: 2)

      assert length(rest) == 1
    end
  end
end
