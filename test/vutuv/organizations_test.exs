defmodule Vutuv.OrganizationsTest do
  @moduledoc """
  The verified-organization context (issue #929): claim → domain proof (DNS TXT /
  well-known file) → active, plus engagement, the directory and the periodic
  re-check. `async: false` because the verification tests flip the global
  `:verify_organization_domains` flag and inject a DNS resolver / Req adapter.
  """
  use Vutuv.DataCase, async: false

  import Swoosh.TestAssertions

  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Organizations.OrganizationDomain
  alias Vutuv.Repo

  @valid %{
    "kind" => "company",
    "name" => "Acme GmbH",
    "website_url" => "https://acme.example",
    "street_address" => "Hauptstrasse 1",
    "zip_code" => "50667",
    "city" => "Köln",
    "country" => "DE"
  }

  defp enable_verification(_context) do
    Application.put_env(:vutuv, :verify_organization_domains, true)
    on_exit(fn -> Application.put_env(:vutuv, :verify_organization_domains, false) end)
    :ok
  end

  defp stub_dns(token) do
    expected = ~c"vutuv-organization-verify=#{token}"
    Application.put_env(:vutuv, :organizations_dns_resolver, fn _host -> [[expected]] end)
    on_exit(fn -> Application.delete_env(:vutuv, :organizations_dns_resolver) end)
  end

  defp stub_well_known(body) do
    Application.put_env(:vutuv, :organizations_req_options,
      adapter: fn req -> {req, %Req.Response{status: 200, body: body}} end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :organizations_req_options) end)
  end

  describe "create_pending_organization/3" do
    test "creates a pending organization, an owner role and a primary claim domain" do
      user = insert(:activated_user)

      assert {:ok, %{organization: organization, domain: domain}} =
               Organizations.create_pending_organization(user, @valid, "dns")

      assert organization.status == "pending"
      assert organization.slug == "acme-gmbh"
      assert organization.country == "DE"
      assert organization.created_by_user_id == user.id
      assert domain.domain == "acme.example"
      assert domain.primary?
      assert domain.method == "dns"
      assert is_binary(domain.verification_token)
      assert Organizations.can_manage?(organization, user)
      refute Organizations.public_visible?(organization)
    end

    test "requires the website URL (the domain source)" do
      user = insert(:activated_user)
      attrs = Map.delete(@valid, "website_url")

      assert {:error, changeset} = Organizations.create_pending_organization(user, attrs, "dns")
      assert changeset.errors[:website_url]
    end

    test "requires the city and country" do
      user = insert(:activated_user)

      assert {:error, city_cs} =
               Organizations.create_pending_organization(user, Map.delete(@valid, "city"), "dns")

      assert city_cs.errors[:city]

      assert {:error, country_cs} =
               Organizations.create_pending_organization(
                 user,
                 Map.delete(@valid, "country"),
                 "dns"
               )

      assert country_cs.errors[:country]
    end

    test "street address and postal code are optional (countries without them)" do
      user = insert(:activated_user)
      attrs = @valid |> Map.delete("street_address") |> Map.delete("zip_code")

      assert {:ok, %{organization: organization}} =
               Organizations.create_pending_organization(user, attrs, "dns")

      assert organization.status == "pending"
      assert is_nil(organization.street_address)
      assert is_nil(organization.zip_code)
      assert organization.city == "Köln"
    end

    test "rejects an invalid country code" do
      user = insert(:activated_user)
      attrs = Map.put(@valid, "country", "XX")

      assert {:error, changeset} = Organizations.create_pending_organization(user, attrs, "dns")
      assert changeset.errors[:country]
    end

    test "a second claim on the same domain is rejected" do
      user1 = insert(:activated_user)
      user2 = insert(:activated_user)

      assert {:ok, _} = Organizations.create_pending_organization(user1, @valid, "dns")

      attrs = Map.put(@valid, "name", "Acme Two")

      assert {:error, :domain_taken} =
               Organizations.create_pending_organization(user2, attrs, "well_known")
    end
  end

  describe "kind (Art)" do
    test "the claim wizard requires a kind" do
      user = insert(:activated_user)
      attrs = Map.delete(@valid, "kind")

      assert {:error, changeset} = Organizations.create_pending_organization(user, attrs, "dns")
      assert changeset.errors[:kind]
    end

    test "an unknown kind is rejected" do
      user = insert(:activated_user)
      attrs = Map.put(@valid, "kind", "spaceship")

      assert {:error, changeset} = Organizations.create_pending_organization(user, attrs, "dns")
      assert changeset.errors[:kind]
    end

    test "a chosen kind is stored (a Verein is not a company)" do
      user = insert(:activated_user)
      attrs = Map.put(@valid, "kind", "association")

      assert {:ok, %{organization: organization}} =
               Organizations.create_pending_organization(user, attrs, "dns")

      assert organization.kind == :association
    end

    test "every kind has a label and a schema.org type" do
      for kind <- Organization.kinds() do
        assert is_binary(Organization.kind_label(kind))
        assert Organization.schema_org_type(kind) =~ ~r/^[A-Z]/
      end

      assert Organization.schema_org_type(:government) == "GovernmentOrganization"
      assert Organization.schema_org_type(:education) == "EducationalOrganization"
      assert Organization.kind_options() |> length() == length(Organization.kinds())
    end
  end

  describe "verify_dns/2" do
    setup [:enable_verification]

    test "activates the organization and alerts the operator when the TXT record matches" do
      user = insert(:activated_user)

      {:ok, %{organization: organization, domain: domain}} =
        Organizations.create_pending_organization(user, @valid, "dns")

      stub_dns(domain.verification_token)

      assert {:ok, organization} = Organizations.verify_dns(organization, domain)
      assert organization.status == "active"
      assert organization.verified_at

      domain = Repo.get!(OrganizationDomain, domain.id)
      assert domain.verified_at
      assert Organizations.public_visible?(organization)
      assert_email_sent(fn email -> assert email.subject =~ "verifiziert" end)
    end

    test "leaves the organization pending when the record is absent" do
      user = insert(:activated_user)

      {:ok, %{organization: organization, domain: domain}} =
        Organizations.create_pending_organization(user, @valid, "dns")

      Application.put_env(:vutuv, :organizations_dns_resolver, fn _host -> [] end)
      on_exit(fn -> Application.delete_env(:vutuv, :organizations_dns_resolver) end)

      assert {:error, :not_found} = Organizations.verify_dns(organization, domain)
      assert Repo.get!(Organization, organization.id).status == "pending"
    end
  end

  describe "verify_well_known/2" do
    setup [:enable_verification]

    test "activates the organization when the file serves the token" do
      user = insert(:activated_user)

      {:ok, %{organization: organization, domain: domain}} =
        Organizations.create_pending_organization(user, @valid, "well_known")

      stub_well_known(domain.verification_token <> "\n")

      assert {:ok, organization} = Organizations.verify_well_known(organization, domain)
      assert organization.status == "active"
    end
  end

  describe "verification disabled" do
    test "verify_dns is a no-op when the flag is off" do
      user = insert(:activated_user)

      {:ok, %{organization: organization, domain: domain}} =
        Organizations.create_pending_organization(user, @valid, "dns")

      # flag stays false (test default)
      assert {:error, :not_found} = Organizations.verify_dns(organization, domain)
    end
  end

  describe "recheck_domain/1" do
    setup [:enable_verification]

    test "starts a grace window, then demotes the domain and organization" do
      user = insert(:activated_user)

      {:ok, %{organization: organization, domain: domain}} =
        Organizations.create_pending_organization(user, @valid, "dns")

      stub_dns(domain.verification_token)
      {:ok, _organization} = Organizations.verify_dns(organization, domain)
      domain = Repo.get!(OrganizationDomain, domain.id)
      # Consume the "verified" operator notice so the demote assertion below
      # matches the second message, not this one.
      assert_email_sent(fn email -> assert email.subject =~ "Firmenseite verifiziert" end)

      # The record vanishes.
      Application.put_env(:vutuv, :organizations_dns_resolver, fn _host -> [] end)

      assert :grace_started = Organizations.recheck_domain(domain)
      domain = Repo.get!(OrganizationDomain, domain.id)
      assert domain.grace_deadline_at
      assert domain.verified_at

      # Backdate the grace deadline to force expiry, then re-check.
      past = NaiveDateTime.add(NaiveDateTime.utc_now(), -3600) |> NaiveDateTime.truncate(:second)

      {:ok, domain} =
        domain |> OrganizationDomain.check_changeset(%{grace_deadline_at: past}) |> Repo.update()

      assert :demoted_organization = Organizations.recheck_domain(domain)
      assert Repo.get!(OrganizationDomain, domain.id).verified_at == nil
      assert Repo.get!(Organization, organization.id).status == "pending"
      assert_email_sent(fn email -> assert email.subject =~ "nicht mehr verifiziert" end)
    end

    test "demoting the primary domain of a still-verified org moves the badge to another domain" do
      user = insert(:activated_user)

      {:ok, %{organization: organization, domain: primary}} =
        Organizations.create_pending_organization(user, @valid, "dns")

      stub_dns(primary.verification_token)
      {:ok, _} = Organizations.verify_dns(organization, primary)
      primary = Repo.get!(OrganizationDomain, primary.id)
      assert primary.primary?

      # A second, independently verified domain, so the org stays active when the
      # primary later fails.
      {:ok, second} = Organizations.add_domain(organization, "second.example.org", "dns")
      stub_dns(second.verification_token)
      {:ok, _} = Organizations.verify_dns(organization, second)

      # The primary's record vanishes; force past grace and re-check it.
      Application.put_env(:vutuv, :organizations_dns_resolver, fn _host -> [] end)

      assert :grace_started =
               Organizations.recheck_domain(Repo.get!(OrganizationDomain, primary.id))

      past = NaiveDateTime.add(NaiveDateTime.utc_now(), -3600) |> NaiveDateTime.truncate(:second)

      {:ok, primary} =
        Repo.get!(OrganizationDomain, primary.id)
        |> OrganizationDomain.check_changeset(%{grace_deadline_at: past})
        |> Repo.update()

      assert :demoted_domain = Organizations.recheck_domain(primary)

      # The demoted primary loses BOTH its verification and its primary flag, and
      # a still-verified domain takes over the badge (no false "verified via …").
      primary = Repo.get!(OrganizationDomain, primary.id)
      refute primary.primary?
      assert primary.verified_at == nil

      organization = Repo.get!(Organization, organization.id)
      assert organization.status == "active"
      assert Organizations.primary_domain(organization).id == second.id
    end
  end

  describe "domains_due_for_recheck/1 (weekly cutoff)" do
    test "a domain checked within the past week is not due; older than a week is" do
      user = insert(:activated_user)
      {:ok, %{domain: domain}} = Organizations.create_pending_organization(user, @valid, "dns")

      now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      mark = fn days_ago ->
        domain
        |> OrganizationDomain.check_changeset(%{
          verified_at: now,
          last_checked_at: NaiveDateTime.add(now, -days_ago * 86_400)
        })
        |> Repo.update!()
      end

      # Two days ago: inside the weekly window → not due (was due under 24h).
      mark.(2)
      refute domain.id in Enum.map(Organizations.domains_due_for_recheck(now), & &1.id)

      # Eight days ago: past the 7-day interval → due.
      mark.(8)
      assert domain.id in Enum.map(Organizations.domains_due_for_recheck(now), & &1.id)
    end
  end

  describe "engagement" do
    setup do
      owner = insert(:activated_user)

      {:ok, %{organization: organization}} =
        Organizations.create_pending_organization(owner, @valid, "dns")

      organization = organization |> Organization.status_changeset("active") |> Repo.update!()
      %{organization: organization}
    end

    test "like and bookmark are idempotent and counted", %{organization: organization} do
      user = insert(:activated_user)

      assert {:ok, _} = Organizations.like_organization(user, organization)
      assert {:ok, :noop} = Organizations.like_organization(user, organization)
      assert {:ok, _} = Organizations.bookmark_organization(user, organization)

      engagement = Organizations.organization_engagement(organization, user)
      assert engagement.likes == 1
      assert engagement.liked?
      assert engagement.bookmarked?

      assert [c] = Organizations.bookmarked_organizations(user)
      assert c.id == organization.id

      :ok = Organizations.unlike_organization(user, organization)
      assert Organizations.organization_engagement(organization, nil).likes == 0
    end

    test "broadcasts a live like count on the organization topic", %{organization: organization} do
      user = insert(:activated_user)
      Organizations.subscribe(organization.id)

      assert {:ok, _} = Organizations.like_organization(user, organization)
      assert_receive {:organization_counters, %{organization_id: id, likes: 1}}
      assert id == organization.id
    end
  end

  describe "directory_page/1" do
    setup do
      owner = insert(:activated_user)

      {:ok, %{organization: acme}} =
        Organizations.create_pending_organization(owner, @valid, "dns")

      acme = acme |> Organization.status_changeset("active") |> Repo.update!()

      berlin_attrs = %{
        @valid
        | "name" => "Berlin Corp",
          "website_url" => "https://berlin.example",
          "city" => "Berlin"
      }

      {:ok, %{organization: berlin}} =
        Organizations.create_pending_organization(owner, berlin_attrs, "dns")

      berlin = berlin |> Organization.status_changeset("active") |> Repo.update!()

      %{acme: acme, berlin: berlin}
    end

    test "lists active organizations and searches by name and city", %{acme: acme, berlin: berlin} do
      all = Organizations.directory_page()
      assert all.total == 2

      by_name = Organizations.directory_page(search: "acme")
      assert Enum.map(by_name.entries, & &1.id) == [acme.id]

      by_city = Organizations.directory_page(search: "Berlin")
      assert Enum.map(by_city.entries, & &1.id) == [berlin.id]
    end

    test "a pending organization is not in the directory" do
      owner = insert(:activated_user)
      pending_attrs = %{@valid | "name" => "Hidden Co", "website_url" => "https://hidden.example"}
      {:ok, _} = Organizations.create_pending_organization(owner, pending_attrs, "dns")

      refute Enum.any?(Organizations.directory_page().entries, &(&1.name == "Hidden Co"))
    end
  end

  describe "visibility" do
    test "indexable? and agent_visible? track status + seo?/geo?" do
      owner = insert(:activated_user)

      {:ok, %{organization: organization}} =
        Organizations.create_pending_organization(owner, @valid, "dns")

      refute Organizations.indexable?(organization)

      active = %{organization | status: "active", verified_at: NaiveDateTime.utc_now()}
      assert Organizations.indexable?(active)
      assert Organizations.agent_visible?(active)

      refute Organizations.indexable?(%{active | seo?: false})
      refute Organizations.agent_visible?(%{active | geo?: false})
    end
  end
end
