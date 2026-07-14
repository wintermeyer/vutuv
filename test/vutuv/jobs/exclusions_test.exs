defmodule Vutuv.Jobs.ExclusionsTest do
  @moduledoc """
  The privacy-critical core of issue #939: who a job posting is subtracted from.
  Exercises the `excluded?/2` predicate on every dimension (member, organization,
  domain), the block-implies-exclusion rule, the owning-org-staff and
  poster/anonymous exemptions, organization-default inheritance, and the
  board/detail/saved-hub enforcement surfaces.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory
  import Vutuv.JobsHelpers

  alias Vutuv.Jobs
  alias Vutuv.Jobs.Exclusions
  alias Vutuv.Organizations.OrganizationDomain
  alias Vutuv.Organizations.OrganizationRole
  alias Vutuv.Repo
  alias Vutuv.Social

  defp viewer_with_email(host) do
    user = insert(:activated_user)
    insert(:email, user: user, value: "person@#{host}")
    user
  end

  defp verified_domain!(org, domain) do
    Repo.insert!(%OrganizationDomain{
      organization_id: org.id,
      domain: domain,
      method: "dns",
      verification_token: "tok-#{System.unique_integer([:positive])}",
      verified_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second),
      primary?: true
    })
  end

  defp role!(org, user, role \\ "recruiter") do
    Repo.insert!(%OrganizationRole{organization_id: org.id, user_id: user.id, role: role})
  end

  describe "excluded?/2 exemptions" do
    setup do
      poster = poster_fixture()
      %{poster: poster, posting: publish_job!(poster)}
    end

    test "an anonymous viewer is never excluded", %{posting: posting} do
      # Even with a matching domain row present, nil viewer falls through.
      Exclusions.add_posting_domain(posting, %{"domain" => "example.com"})
      refute Exclusions.excluded?(posting, nil)
    end

    test "the poster is never excluded from their own posting", %{
      poster: poster,
      posting: posting
    } do
      insert(:email, user: poster, value: "boss@rival.example")
      {:ok, _} = Exclusions.add_posting_domain(posting, %{"domain" => "rival.example"})
      refute Exclusions.excluded?(posting, poster)
    end
  end

  describe "member dimension" do
    setup do
      posting = publish_job!()
      %{posting: posting}
    end

    test "an excluded member is excluded, others are not", %{posting: posting} do
      target = insert(:activated_user, username: "boss")
      other = insert(:activated_user)

      {:ok, _} = Exclusions.add_posting_member(posting, "@boss")

      assert Exclusions.excluded?(posting, target)
      refute Exclusions.excluded?(posting, other)
    end
  end

  describe "domain dimension" do
    setup do
      posting = publish_job!()
      {:ok, _} = Exclusions.add_posting_domain(posting, %{"domain" => "acme.com"})
      %{posting: posting}
    end

    test "exact domain match is excluded", %{posting: posting} do
      assert Exclusions.excluded?(posting, viewer_with_email("acme.com"))
    end

    test "a subdomain of the listed domain is excluded", %{posting: posting} do
      assert Exclusions.excluded?(posting, viewer_with_email("eu.acme.com"))
    end

    test "an unrelated or lookalike domain is not excluded", %{posting: posting} do
      refute Exclusions.excluded?(posting, viewer_with_email("gmail.com"))
      refute Exclusions.excluded?(posting, viewer_with_email("notacme.com"))
    end
  end

  describe "organization dimension" do
    setup do
      posting = publish_job!()
      excluded_org = insert(:organization)
      {:ok, _} = Exclusions.add_posting_organization(posting, excluded_org.slug)
      %{posting: posting, excluded_org: excluded_org}
    end

    test "a role holder of the excluded org is excluded", %{posting: posting, excluded_org: org} do
      staff = insert(:activated_user)
      role!(org, staff)
      assert Exclusions.excluded?(posting, staff)
    end

    test "a member whose CURRENT work experience links to the excluded org is excluded",
         %{posting: posting, excluded_org: org} do
      member = insert(:activated_user)
      insert(:work_experience, user: member, organization_id: org.id, end_year: nil)
      assert Exclusions.excluded?(posting, member)
    end

    test "a member whose PAST (ended) work experience links to the excluded org is NOT excluded",
         %{posting: posting, excluded_org: org} do
      member = insert(:activated_user)
      insert(:work_experience, user: member, organization_id: org.id, end_year: 2020)
      refute Exclusions.excluded?(posting, member)
    end

    test "a confirmed email at the excluded org's verified domain is excluded",
         %{posting: posting, excluded_org: org} do
      verified_domain!(org, "excluded-co.example")
      assert Exclusions.excluded?(posting, viewer_with_email("careers.excluded-co.example"))
    end
  end

  describe "organization standing default" do
    test "every posting attributed to the org inherits its default exclusions" do
      poster = poster_fixture()
      org = insert(:organization)
      role!(org, poster, "owner")

      {:ok, _} = Exclusions.add_organization_domain(org, %{"domain" => "rival.example"})

      p1 = publish_job!(poster, %{}, organization: org)
      p2 = publish_job!(poster, %{}, organization: org)
      personal = publish_job!(poster)

      rival = viewer_with_email("rival.example")

      assert Exclusions.excluded?(p1, rival)
      assert Exclusions.excluded?(p2, rival)
      # The default rides only on org-attributed postings, not a personal one.
      refute Exclusions.excluded?(personal, rival)
    end

    test "effective set is the union of posting rows and org-default rows" do
      poster = poster_fixture()
      org = insert(:organization)
      role!(org, poster, "owner")
      {:ok, _} = Exclusions.add_organization_domain(org, %{"domain" => "orgwide.example"})

      posting = publish_job!(poster, %{}, organization: org)
      {:ok, _} = Exclusions.add_posting_domain(posting, %{"domain" => "postingonly.example"})

      assert Exclusions.excluded?(posting, viewer_with_email("orgwide.example"))
      assert Exclusions.excluded?(posting, viewer_with_email("postingonly.example"))
    end
  end

  describe "block implies exclusion" do
    test "a viewer the poster blocked is excluded" do
      poster = poster_fixture()
      posting = publish_job!(poster)
      blocked = insert(:activated_user)

      {:ok, _} = Social.block_user(poster, blocked)
      assert Exclusions.excluded?(posting, blocked)
    end

    test "a viewer who blocked the poster is excluded (either direction)" do
      poster = poster_fixture()
      posting = publish_job!(poster)
      blocker = insert(:activated_user)

      {:ok, _} = Social.block_user(blocker, poster)
      assert Exclusions.excluded?(posting, blocker)
    end
  end

  describe "owning-organization staff exemption" do
    test "a role holder of the owning org sees the posting even when a rule would exclude them" do
      poster = poster_fixture()
      org = insert(:organization)
      role!(org, poster, "owner")
      posting = publish_job!(poster, %{}, organization: org)

      staff = insert(:activated_user)
      role!(org, staff, "recruiter")
      insert(:email, user: staff, value: "rec@rival.example")
      {:ok, _} = Exclusions.add_posting_domain(posting, %{"domain" => "rival.example"})

      refute Exclusions.excluded?(posting, staff)
    end
  end

  describe "enforcement surfaces" do
    test "the board subtracts a posting the viewer is excluded from" do
      posting = publish_job!()
      {:ok, _} = Exclusions.add_posting_domain(posting, %{"domain" => "acme.com"})

      excluded = viewer_with_email("acme.com")
      other = viewer_with_email("gmail.com")

      excluded_ids = Jobs.board_page(excluded, Jobs.board_filters(%{}, excluded)) |> entry_ids()
      other_ids = Jobs.board_page(other, Jobs.board_filters(%{}, other)) |> entry_ids()

      refute posting.id in excluded_ids
      assert posting.id in other_ids
    end

    test "visible_to?/2 hides an excluded signed-in viewer but not the anonymous public" do
      posting = publish_job!()
      {:ok, _} = Exclusions.add_posting_domain(posting, %{"domain" => "acme.com"})
      excluded = viewer_with_email("acme.com")

      refute Jobs.visible_to?(posting, excluded)
      assert Jobs.visible_to?(posting, nil)
    end

    test "fetch_visible_job_posting/2 returns not-found for an excluded viewer" do
      posting = publish_job!()
      {:ok, _} = Exclusions.add_posting_domain(posting, %{"domain" => "acme.com"})
      excluded = viewer_with_email("acme.com")

      assert {:error, :not_found} = Jobs.fetch_visible_job_posting(posting.slug, excluded)
      assert {:ok, _} = Jobs.fetch_visible_job_posting(posting.slug, nil)
    end

    test "the saved (bookmark) hub drops a posting the member was later excluded from" do
      posting = publish_job!()
      member = viewer_with_email("acme.com")
      {:ok, _} = Jobs.bookmark_job_posting(member, posting)

      before = Jobs.saved_job_postings_page(member, :bookmark, []) |> entry_ids()
      assert posting.id in before

      {:ok, _} = Exclusions.add_posting_domain(posting, %{"domain" => "acme.com"})
      after_ids = Jobs.saved_job_postings_page(member, :bookmark, []) |> entry_ids()
      refute posting.id in after_ids
    end
  end

  describe "CRUD guards" do
    setup do
      poster = poster_fixture()
      %{poster: poster, posting: publish_job!(poster)}
    end

    test "cannot exclude the poster as a member", %{poster: poster, posting: posting} do
      assert {:error, :poster} = Exclusions.add_posting_member(posting, "@#{poster.username}")
    end

    test "cannot exclude the owning organization from its own posting", %{poster: poster} do
      org = insert(:organization)
      role!(org, poster, "owner")
      posting = publish_job!(poster, %{}, organization: org)

      assert {:error, :owning_org} = Exclusions.add_posting_organization(posting, org.slug)
    end

    test "an unknown @handle is not_found", %{posting: posting} do
      assert {:error, :not_found} = Exclusions.add_posting_member(posting, "@nobody-here")
    end

    test "a duplicate member row is rejected", %{posting: posting} do
      insert(:activated_user, username: "dupe")
      assert {:ok, _} = Exclusions.add_posting_member(posting, "@dupe")
      assert {:error, :duplicate} = Exclusions.add_posting_member(posting, "@dupe")
    end

    test "a malformed domain is a changeset error", %{posting: posting} do
      assert {:error, changeset} =
               Exclusions.add_posting_domain(posting, %{"domain" => "not a domain"})

      refute changeset.valid?
    end

    test "a pasted URL is normalized to a bare host", %{posting: posting} do
      assert {:ok, row} =
               Exclusions.add_posting_domain(posting, %{"domain" => "https://Acme.COM/careers"})

      assert row.domain == "acme.com"
    end

    test "remove is scoped to the subject and idempotent", %{posting: posting} do
      {:ok, row} = Exclusions.add_posting_domain(posting, %{"domain" => "acme.com"})
      assert :ok = Exclusions.remove_from_posting(posting, row.id)
      assert Exclusions.list_for_posting(posting) == []
      assert :ok = Exclusions.remove_from_posting(posting, row.id)
    end

    test "an organization default cannot exclude itself" do
      org = insert(:organization)
      assert {:error, :self} = Exclusions.add_organization_organization(org, org.slug)
    end
  end

  describe "deletion cascade" do
    test "deleting the excluded member removes their exclusion rows" do
      posting = publish_job!()
      target = insert(:activated_user, username: "leaving")
      {:ok, _} = Exclusions.add_posting_member(posting, "@leaving")
      assert length(Exclusions.list_for_posting(posting)) == 1

      {:ok, _} = Vutuv.Accounts.delete_user(target)
      assert Exclusions.list_for_posting(posting) == []
    end

    test "deleting the posting removes its exclusion rows" do
      posting = publish_job!()
      {:ok, _} = Exclusions.add_posting_domain(posting, %{"domain" => "acme.com"})
      {:ok, _} = Jobs.delete_job_posting(posting)
      assert Exclusions.list_for_posting(posting) == []
    end
  end

  defp entry_ids(%{entries: entries}), do: Enum.map(entries, & &1.id)
end
