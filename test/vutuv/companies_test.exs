defmodule Vutuv.CompaniesTest do
  @moduledoc """
  The verified-company context (issue #929): claim → domain proof (DNS TXT /
  well-known file) → active, plus engagement, the directory and the periodic
  re-check. `async: false` because the verification tests flip the global
  `:verify_company_domains` flag and inject a DNS resolver / Req adapter.
  """
  use Vutuv.DataCase, async: false

  import Swoosh.TestAssertions

  alias Vutuv.Companies
  alias Vutuv.Companies.Company
  alias Vutuv.Companies.CompanyDomain
  alias Vutuv.Repo

  @valid %{
    "name" => "Acme GmbH",
    "website_url" => "https://acme.example",
    "street_address" => "Hauptstrasse 1",
    "zip_code" => "50667",
    "city" => "Köln",
    "country" => "DE"
  }

  defp enable_verification(_context) do
    Application.put_env(:vutuv, :verify_company_domains, true)
    on_exit(fn -> Application.put_env(:vutuv, :verify_company_domains, false) end)
    :ok
  end

  defp stub_dns(token) do
    expected = ~c"vutuv-company-verify=#{token}"
    Application.put_env(:vutuv, :companies_dns_resolver, fn _host -> [[expected]] end)
    on_exit(fn -> Application.delete_env(:vutuv, :companies_dns_resolver) end)
  end

  defp stub_well_known(body) do
    Application.put_env(:vutuv, :companies_req_options,
      adapter: fn req -> {req, %Req.Response{status: 200, body: body}} end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :companies_req_options) end)
  end

  describe "create_pending_company/3" do
    test "creates a pending company, an owner role and a primary claim domain" do
      user = insert(:activated_user)

      assert {:ok, %{company: company, domain: domain}} =
               Companies.create_pending_company(user, @valid, "dns")

      assert company.status == "pending"
      assert company.slug == "acme-gmbh"
      assert company.country == "DE"
      assert company.created_by_user_id == user.id
      assert domain.domain == "acme.example"
      assert domain.primary?
      assert domain.method == "dns"
      assert is_binary(domain.verification_token)
      assert Companies.can_manage?(company, user)
      refute Companies.public_visible?(company)
    end

    test "requires the website URL (the domain source)" do
      user = insert(:activated_user)
      attrs = Map.delete(@valid, "website_url")

      assert {:error, changeset} = Companies.create_pending_company(user, attrs, "dns")
      assert changeset.errors[:website_url]
    end

    test "requires the city and country" do
      user = insert(:activated_user)

      assert {:error, city_cs} =
               Companies.create_pending_company(user, Map.delete(@valid, "city"), "dns")

      assert city_cs.errors[:city]

      assert {:error, country_cs} =
               Companies.create_pending_company(user, Map.delete(@valid, "country"), "dns")

      assert country_cs.errors[:country]
    end

    test "street address and postal code are optional (countries without them)" do
      user = insert(:activated_user)
      attrs = @valid |> Map.delete("street_address") |> Map.delete("zip_code")

      assert {:ok, %{company: company}} = Companies.create_pending_company(user, attrs, "dns")
      assert company.status == "pending"
      assert is_nil(company.street_address)
      assert is_nil(company.zip_code)
      assert company.city == "Köln"
    end

    test "rejects an invalid country code" do
      user = insert(:activated_user)
      attrs = Map.put(@valid, "country", "XX")

      assert {:error, changeset} = Companies.create_pending_company(user, attrs, "dns")
      assert changeset.errors[:country]
    end

    test "a second claim on the same domain is rejected" do
      user1 = insert(:activated_user)
      user2 = insert(:activated_user)

      assert {:ok, _} = Companies.create_pending_company(user1, @valid, "dns")

      attrs = Map.put(@valid, "name", "Acme Two")

      assert {:error, :domain_taken} =
               Companies.create_pending_company(user2, attrs, "well_known")
    end
  end

  describe "verify_dns/2" do
    setup [:enable_verification]

    test "activates the company and alerts the operator when the TXT record matches" do
      user = insert(:activated_user)

      {:ok, %{company: company, domain: domain}} =
        Companies.create_pending_company(user, @valid, "dns")

      stub_dns(domain.verification_token)

      assert {:ok, company} = Companies.verify_dns(company, domain)
      assert company.status == "active"
      assert company.verified_at

      domain = Repo.get!(CompanyDomain, domain.id)
      assert domain.verified_at
      assert Companies.public_visible?(company)
      assert_email_sent(fn email -> assert email.subject =~ "verifiziert" end)
    end

    test "leaves the company pending when the record is absent" do
      user = insert(:activated_user)

      {:ok, %{company: company, domain: domain}} =
        Companies.create_pending_company(user, @valid, "dns")

      Application.put_env(:vutuv, :companies_dns_resolver, fn _host -> [] end)
      on_exit(fn -> Application.delete_env(:vutuv, :companies_dns_resolver) end)

      assert {:error, :not_found} = Companies.verify_dns(company, domain)
      assert Repo.get!(Company, company.id).status == "pending"
    end
  end

  describe "verify_well_known/2" do
    setup [:enable_verification]

    test "activates the company when the file serves the token" do
      user = insert(:activated_user)

      {:ok, %{company: company, domain: domain}} =
        Companies.create_pending_company(user, @valid, "well_known")

      stub_well_known(domain.verification_token <> "\n")

      assert {:ok, company} = Companies.verify_well_known(company, domain)
      assert company.status == "active"
    end
  end

  describe "verification disabled" do
    test "verify_dns is a no-op when the flag is off" do
      user = insert(:activated_user)

      {:ok, %{company: company, domain: domain}} =
        Companies.create_pending_company(user, @valid, "dns")

      # flag stays false (test default)
      assert {:error, :not_found} = Companies.verify_dns(company, domain)
    end
  end

  describe "recheck_domain/1" do
    setup [:enable_verification]

    test "starts a grace window, then demotes the domain and company" do
      user = insert(:activated_user)

      {:ok, %{company: company, domain: domain}} =
        Companies.create_pending_company(user, @valid, "dns")

      stub_dns(domain.verification_token)
      {:ok, _company} = Companies.verify_dns(company, domain)
      domain = Repo.get!(CompanyDomain, domain.id)
      # Consume the "verified" operator notice so the demote assertion below
      # matches the second message, not this one.
      assert_email_sent(fn email -> assert email.subject =~ "Firmenseite verifiziert" end)

      # The record vanishes.
      Application.put_env(:vutuv, :companies_dns_resolver, fn _host -> [] end)

      assert :grace_started = Companies.recheck_domain(domain)
      domain = Repo.get!(CompanyDomain, domain.id)
      assert domain.grace_deadline_at
      assert domain.verified_at

      # Backdate the grace deadline to force expiry, then re-check.
      past = NaiveDateTime.add(NaiveDateTime.utc_now(), -3600) |> NaiveDateTime.truncate(:second)

      {:ok, domain} =
        domain |> CompanyDomain.check_changeset(%{grace_deadline_at: past}) |> Repo.update()

      assert :demoted_company = Companies.recheck_domain(domain)
      assert Repo.get!(CompanyDomain, domain.id).verified_at == nil
      assert Repo.get!(Company, company.id).status == "pending"
      assert_email_sent(fn email -> assert email.subject =~ "nicht mehr verifiziert" end)
    end
  end

  describe "domains_due_for_recheck/1 (weekly cutoff)" do
    test "a domain checked within the past week is not due; older than a week is" do
      user = insert(:activated_user)
      {:ok, %{domain: domain}} = Companies.create_pending_company(user, @valid, "dns")

      now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      mark = fn days_ago ->
        domain
        |> CompanyDomain.check_changeset(%{
          verified_at: now,
          last_checked_at: NaiveDateTime.add(now, -days_ago * 86_400)
        })
        |> Repo.update!()
      end

      # Two days ago: inside the weekly window → not due (was due under 24h).
      mark.(2)
      refute domain.id in Enum.map(Companies.domains_due_for_recheck(now), & &1.id)

      # Eight days ago: past the 7-day interval → due.
      mark.(8)
      assert domain.id in Enum.map(Companies.domains_due_for_recheck(now), & &1.id)
    end
  end

  describe "engagement" do
    setup do
      owner = insert(:activated_user)
      {:ok, %{company: company}} = Companies.create_pending_company(owner, @valid, "dns")
      company = company |> Company.status_changeset("active") |> Repo.update!()
      %{company: company}
    end

    test "like and bookmark are idempotent and counted", %{company: company} do
      user = insert(:activated_user)

      assert {:ok, _} = Companies.like_company(user, company)
      assert {:ok, :noop} = Companies.like_company(user, company)
      assert {:ok, _} = Companies.bookmark_company(user, company)

      engagement = Companies.company_engagement(company, user)
      assert engagement.likes == 1
      assert engagement.liked?
      assert engagement.bookmarked?

      assert [c] = Companies.bookmarked_companies(user)
      assert c.id == company.id

      :ok = Companies.unlike_company(user, company)
      assert Companies.company_engagement(company, nil).likes == 0
    end

    test "broadcasts a live like count on the company topic", %{company: company} do
      user = insert(:activated_user)
      Companies.subscribe(company.id)

      assert {:ok, _} = Companies.like_company(user, company)
      assert_receive {:company_counters, %{company_id: id, likes: 1}}
      assert id == company.id
    end
  end

  describe "directory_page/1" do
    setup do
      owner = insert(:activated_user)

      {:ok, %{company: acme}} = Companies.create_pending_company(owner, @valid, "dns")
      acme = acme |> Company.status_changeset("active") |> Repo.update!()

      berlin_attrs = %{
        @valid
        | "name" => "Berlin Corp",
          "website_url" => "https://berlin.example",
          "city" => "Berlin"
      }

      {:ok, %{company: berlin}} = Companies.create_pending_company(owner, berlin_attrs, "dns")
      berlin = berlin |> Company.status_changeset("active") |> Repo.update!()

      %{acme: acme, berlin: berlin}
    end

    test "lists active companies and searches by name and city", %{acme: acme, berlin: berlin} do
      all = Companies.directory_page()
      assert all.total == 2

      by_name = Companies.directory_page(search: "acme")
      assert Enum.map(by_name.entries, & &1.id) == [acme.id]

      by_city = Companies.directory_page(search: "Berlin")
      assert Enum.map(by_city.entries, & &1.id) == [berlin.id]
    end

    test "a pending company is not in the directory" do
      owner = insert(:activated_user)
      pending_attrs = %{@valid | "name" => "Hidden Co", "website_url" => "https://hidden.example"}
      {:ok, _} = Companies.create_pending_company(owner, pending_attrs, "dns")

      refute Enum.any?(Companies.directory_page().entries, &(&1.name == "Hidden Co"))
    end
  end

  describe "visibility" do
    test "indexable? and agent_visible? track status + seo?/geo?" do
      owner = insert(:activated_user)
      {:ok, %{company: company}} = Companies.create_pending_company(owner, @valid, "dns")

      refute Companies.indexable?(company)

      active = %{company | status: "active", verified_at: NaiveDateTime.utc_now()}
      assert Companies.indexable?(active)
      assert Companies.agent_visible?(active)

      refute Companies.indexable?(%{active | seo?: false})
      refute Companies.agent_visible?(%{active | geo?: false})
    end
  end
end
