defmodule Vutuv.OrganizationsLinkingTest do
  @moduledoc """
  Linking a work experience to a verified organization page (issue #931): the
  editor's suggestion match, the canonical link path, the changeset guard that
  only ever links to a **verified** organization, and the organization page's People
  section (which member appears, in which order, under the directory privacy
  gate).
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Organizations
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo

  describe "canonical_path/1" do
    test "a handle-less organization lives at /organizations/:slug" do
      organization = insert(:organization, slug: "acme-gmbh", username: nil)
      assert Organizations.canonical_path(organization) == "/organizations/acme-gmbh"
    end

    test "an organization with a root handle is canonical at /:handle" do
      handle = "acme#{System.unique_integer([:positive])}"
      organization = insert(:organization, slug: "acme-gmbh", username: handle)
      assert Organizations.canonical_path(organization) == "/#{handle}"
    end
  end

  describe "suggest_organization_for_org/1" do
    test "matches a verified organization's name case-insensitively" do
      organization = insert(:organization, name: "ACME GmbH")
      assert %{id: id} = Organizations.suggest_organization_for_org("acme gmbh")
      assert id == organization.id
    end

    test "matches an alias case-insensitively" do
      organization = insert(:organization, name: "Acme GmbH")
      {:ok, _} = Organizations.add_alias(organization, "ACME Deutschland", "brand")

      assert %{id: id} = Organizations.suggest_organization_for_org("acme deutschland")
      assert id == organization.id
    end

    test "requires the whole name to match (no substring)" do
      insert(:organization, name: "Acme Foundation")
      assert Organizations.suggest_organization_for_org("Acme") == nil
    end

    test "never suggests a pending or frozen organization" do
      insert(:organization, name: "Pending Co", status: "pending", verified_at: nil)

      insert(:organization,
        name: "Frozen Co",
        frozen_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
      )

      assert Organizations.suggest_organization_for_org("Pending Co") == nil
      assert Organizations.suggest_organization_for_org("Frozen Co") == nil
    end

    test "returns nil for a blank or too-short term" do
      assert Organizations.suggest_organization_for_org("") == nil
      assert Organizations.suggest_organization_for_org("a") == nil
      assert Organizations.suggest_organization_for_org(nil) == nil
    end
  end

  describe "the work-experience link guard" do
    setup do
      %{user: insert(:activated_user)}
    end

    test "links to an active organization", %{user: user} do
      organization = insert(:organization)

      changeset =
        WorkExperience.changeset(%WorkExperience{user_id: user.id}, %{
          "title" => "Engineer",
          "organization" => "Acme",
          "organization_id" => organization.id
        })

      assert {:ok, work} = Repo.insert(changeset)
      assert work.organization_id == organization.id
    end

    test "silently drops a link to a frozen organization (free text stays)", %{user: user} do
      frozen =
        insert(:organization,
          frozen_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
        )

      changeset =
        WorkExperience.changeset(%WorkExperience{user_id: user.id}, %{
          "title" => "Engineer",
          "organization" => "Acme",
          "organization_id" => frozen.id
        })

      assert {:ok, work} = Repo.insert(changeset)
      assert is_nil(work.organization_id)
    end

    test "unlinking sets organization_id back to nil", %{user: user} do
      organization = insert(:organization)
      work = insert(:work_experience, user: user, organization_page: organization)

      changeset = WorkExperience.changeset(work, %{"organization_id" => ""})
      assert {:ok, updated} = Repo.update(changeset)
      assert is_nil(updated.organization_id)
    end
  end

  describe "organization_people_page/2 and organization_people_count/1" do
    setup do
      organization = insert(:organization)
      %{organization: organization}
    end

    test "lists a linked member with their written title", %{organization: organization} do
      user = insert(:activated_user, first_name: "Cara", last_name: "Current")

      insert(:work_experience,
        user: user,
        organization_page: organization,
        title: "Chief Bridge Engineer",
        end_year: nil
      )

      assert Organizations.organization_people_count(organization) == 1

      assert %{entries: [entry], more?: false} =
               Organizations.organization_people_page(organization)

      assert entry.user.id == user.id
      assert entry.title == "Chief Bridge Engineer"
      assert entry.current?
    end

    test "current members lead past members", %{organization: organization} do
      past = insert(:activated_user, first_name: "Aaron", last_name: "Alumni")

      insert(:work_experience,
        user: past,
        organization_page: organization,
        title: "Former Dev",
        start_year: 2015,
        end_year: 2019
      )

      current = insert(:activated_user, first_name: "Zoe", last_name: "Zurzeit")

      insert(:work_experience,
        user: current,
        organization_page: organization,
        title: "Current Dev",
        end_year: nil
      )

      assert %{entries: [first, second]} = Organizations.organization_people_page(organization)
      assert first.user.id == current.id
      assert first.current?
      assert second.user.id == past.id
      refute second.current?
    end

    test "respects the directory privacy gate", %{organization: organization} do
      hidden = insert(:activated_user, noindex?: true)

      insert(:work_experience,
        user: hidden,
        organization_page: organization,
        title: "Hidden",
        end_year: nil
      )

      unconfirmed = insert(:user, email_confirmed?: false)

      insert(:work_experience,
        user: unconfirmed,
        organization_page: organization,
        title: "Unconfirmed",
        end_year: nil
      )

      assert Organizations.organization_people_count(organization) == 0
      assert %{entries: []} = Organizations.organization_people_page(organization)
    end

    test "collapses a member's several roles into one entry, newest current title", %{
      organization: organization
    } do
      user = insert(:activated_user)

      insert(:work_experience,
        user: user,
        organization_page: organization,
        title: "Junior Dev",
        start_year: 2018,
        end_year: 2020
      )

      insert(:work_experience,
        user: user,
        organization_page: organization,
        title: "Senior Dev",
        start_year: 2020,
        end_year: nil
      )

      assert %{entries: [entry]} = Organizations.organization_people_page(organization)
      assert entry.title == "Senior Dev"
      assert entry.current?
    end

    test "paginates with more?/next_offset", %{organization: organization} do
      for i <- 1..3 do
        user = insert(:activated_user, last_name: "Member#{i}")

        insert(:work_experience,
          user: user,
          organization_page: organization,
          title: "Dev",
          end_year: nil
        )
      end

      assert %{entries: entries, more?: true, next_offset: 2} =
               Organizations.organization_people_page(organization, limit: 2)

      assert length(entries) == 2

      assert %{entries: rest, more?: false} =
               Organizations.organization_people_page(organization, limit: 2, offset: 2)

      assert length(rest) == 1
    end
  end
end
