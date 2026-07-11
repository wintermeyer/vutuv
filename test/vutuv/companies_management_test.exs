defmodule Vutuv.CompaniesManagementTest do
  @moduledoc """
  Company team roles, multi-domain management and name aliases (issue #930).
  `async: false` because the domain-add/verify flow flips the global
  `:verify_company_domains` flag and injects a DNS resolver, like the #929
  verification tests.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Companies
  alias Vutuv.Companies.CompanyRole
  alias Vutuv.Repo

  @valid %{
    "name" => "Acme GmbH",
    "website_url" => "https://acme.example",
    "street_address" => "Hauptstrasse 1",
    "zip_code" => "50667",
    "city" => "Köln",
    "country" => "DE"
  }

  setup do
    Application.put_env(:vutuv, :verify_company_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_company_domains, false)
      Application.delete_env(:vutuv, :companies_dns_resolver)
    end)

    :ok
  end

  defp stub_dns(token) do
    Application.put_env(:vutuv, :companies_dns_resolver, fn _host ->
      [[~c"vutuv-company-verify=#{token}"]]
    end)
  end

  defp active_company(attrs \\ %{}) do
    owner = insert(:activated_user)
    merged = Map.merge(@valid, attrs)

    {:ok, %{company: company, domain: domain}} =
      Companies.create_pending_company(owner, merged, "dns")

    stub_dns(domain.verification_token)
    {:ok, company} = Companies.verify_dns(company, domain)
    {company, owner}
  end

  describe "roles" do
    test "owner powers vs admin vs recruiter" do
      {company, owner} = active_company()
      admin = insert(:activated_user)
      recruiter = insert(:activated_user)
      stranger = insert(:activated_user)

      {:ok, _} = Companies.add_role(company, admin, "admin", owner)
      {:ok, _} = Companies.add_role(company, recruiter, "recruiter", owner)

      assert Companies.owner?(company, owner)
      refute Companies.owner?(company, admin)

      assert Companies.can_edit_page?(company, owner)
      assert Companies.can_edit_page?(company, admin)
      refute Companies.can_edit_page?(company, recruiter)

      assert Companies.can_manage_roles?(company, owner)
      refute Companies.can_manage_roles?(company, admin)
      refute Companies.can_manage_domains?(company, recruiter)

      # A recruiter is still staff (sees a frozen/pending page)…
      assert Companies.can_manage?(company, recruiter)
      # …but a stranger is not.
      refute Companies.can_manage?(company, stranger)
    end

    test "add_role notifies the member and rejects a duplicate" do
      {company, owner} = active_company()
      member = insert(:activated_user)

      assert {:ok, _role} = Companies.add_role(company, member, "admin", owner)
      assert {:error, :already_member} = Companies.add_role(company, member, "recruiter", owner)
    end

    test "the last owner cannot be removed or demoted" do
      {company, owner} = active_company()
      owner_role = Repo.get_by(CompanyRole, company_id: company.id, user_id: owner.id)

      assert {:error, :last_owner} = Companies.remove_role(owner_role)
      assert {:error, :last_owner} = Companies.update_role(owner_role, "admin", owner)

      # A second owner lifts the guard.
      other = insert(:activated_user)
      {:ok, _} = Companies.add_role(company, other, "owner", owner)
      assert {:ok, _} = Companies.update_role(owner_role, "admin", owner)
    end

    test "list_roles orders owner, admin, recruiter" do
      {company, owner} = active_company()
      r = insert(:activated_user)
      a = insert(:activated_user)
      {:ok, _} = Companies.add_role(company, r, "recruiter", owner)
      {:ok, _} = Companies.add_role(company, a, "admin", owner)

      assert Enum.map(Companies.list_roles(company), & &1.role) == ["owner", "admin", "recruiter"]
    end
  end

  describe "domains" do
    test "add a second domain, verify it, and pick a primary" do
      {company, _owner} = active_company()

      assert {:ok, second} = Companies.add_domain(company, "https://acme.de", "dns")
      refute second.primary?
      refute second.verified_at

      stub_dns(second.verification_token)
      {:ok, _company} = Companies.verify_domain(company, second)
      second = Companies.get_domain(company, second.id)
      assert second.verified_at

      assert length(Companies.verified_domains(company)) == 2

      # Make the new domain primary; the badge follows.
      {:ok, promoted} = Companies.set_primary_domain(company, second)
      assert promoted.primary?
      assert Companies.primary_domain(company).domain == "acme.de"
    end

    test "an unverified domain cannot be made primary" do
      {company, _owner} = active_company()
      {:ok, second} = Companies.add_domain(company, "https://acme.de", "dns")
      assert {:error, :not_verified} = Companies.set_primary_domain(company, second)
    end

    test "a domain already claimed elsewhere is refused" do
      {company_a, _} = active_company()

      {company_b, _} =
        active_company(%{"name" => "Beta AG", "website_url" => "https://beta.example"})

      taken = Companies.primary_domain(company_b).domain
      assert {:error, :domain_taken} = Companies.add_domain(company_a, "https://#{taken}", "dns")
    end

    test "the last verified domain cannot be removed; removing the primary auto-promotes" do
      {company, _owner} = active_company()
      primary = Companies.primary_domain(company)

      assert {:error, :last_domain} = Companies.remove_domain(company, primary)

      {:ok, second} = Companies.add_domain(company, "https://acme.de", "dns")
      stub_dns(second.verification_token)
      {:ok, _} = Companies.verify_domain(company, second)

      # Now the primary can go; the other verified domain becomes primary.
      {:ok, _} = Companies.remove_domain(company, primary)
      assert Companies.primary_domain(company).domain == "acme.de"
      assert length(Companies.verified_domains(company)) == 1
    end
  end

  describe "aliases" do
    test "add and list aliases; the directory finds a company under an alias" do
      {company, _owner} = active_company()

      {:ok, brand} = Companies.add_alias(company, "AcmeCorp", "brand")
      assert brand.kind == "brand"
      assert Enum.map(Companies.list_aliases(company), & &1.name) == ["AcmeCorp"]

      page = Companies.directory_page(search: "AcmeCorp")
      assert Enum.any?(page.entries, &(&1.id == company.id))
    end

    test "renaming appends the old name as a former alias and keeps the slug" do
      {company, _owner} = active_company()
      slug = company.slug

      {:ok, renamed} = Companies.update_company(company, %{"name" => "Acme Holding GmbH"})
      assert renamed.slug == slug
      assert renamed.name == "Acme Holding GmbH"

      former = Companies.list_aliases(renamed)
      assert Enum.any?(former, &(&1.name == "Acme GmbH" and &1.kind == "former"))
    end

    test "an alias equal to another verified company's name is flagged for the admin queue" do
      {company_a, _} = active_company()

      {_company_b, _} =
        active_company(%{"name" => "Globex SE", "website_url" => "https://globex.example"})

      assert {:ok, flagged} = Companies.add_alias(company_a, "Globex SE", "brand")
      assert flagged.flagged_at
      assert Companies.flagged_aliases_count() == 1

      # A harmless, unique alias is not flagged.
      {:ok, fine} = Companies.add_alias(company_a, "Totally Unique Name 4711", "brand")
      refute fine.flagged_at
    end
  end
end
