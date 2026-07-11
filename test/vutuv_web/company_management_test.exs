defmodule VutuvWeb.CompanyManagementTest do
  @moduledoc """
  The company management web surface (issue #930): the owner-only roles and
  domains pages, alias editing on the edit page, the /companies agent formats
  carrying aliases, and the /admin/companies oversight dashboard. `async: false`
  because domain verification flips the global `:verify_company_domains` flag and
  injects a DNS resolver.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Companies

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
      [[~c"vutuv-verify=#{token}"]]
    end)
  end

  # An active company owned by `owner` (an already-persisted %User{}).
  defp active_company_for(owner, attrs \\ %{}) do
    {:ok, %{company: company, domain: domain}} =
      Companies.create_pending_company(owner, Map.merge(@valid, attrs), "dns")

    stub_dns(domain.verification_token)
    {:ok, company} = Companies.verify_dns(company, domain)
    company
  end

  describe "roles page" do
    test "owner adds a member; the new admin can edit but not manage roles", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      company = active_company_for(owner)
      member = insert(:activated_user)

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.slug}/roles")

      view
      |> element("#add-member-form")
      |> render_submit(%{"identifier" => "@" <> member.username, "role" => "admin"})

      assert render(view) =~ member.username
      assert Companies.role_of(company, member) == "admin"
    end

    test "the last owner cannot leave", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      company = active_company_for(owner)
      role = Companies.role_of(company, owner) && hd(Companies.list_roles(company))

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.slug}/roles")
      html = view |> element("#role-#{role.id} button", "Leave") |> render_click()

      assert html =~ "at least one owner"
      assert Companies.role_of(company, owner) == "owner"
    end

    test "a logged-in non-member cannot open the roles page", %{conn: conn} do
      # Log in first, so the only PIN in the mailbox is this login's (the company
      # claim below sends the operator's verified-notice email).
      {stranger_conn, _stranger} = create_and_login_user(conn)
      owner = insert(:activated_user)
      company = active_company_for(owner)

      assert stranger_conn |> get(~p"/companies/#{company.slug}/roles") |> response(404)
      assert stranger_conn |> get(~p"/companies/#{company.slug}/domains") |> response(404)
    end
  end

  describe "domains page" do
    test "owner adds and verifies a second domain, then makes it primary", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      company = active_company_for(owner)

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.slug}/domains")

      view
      |> element("#add-domain-form")
      |> render_submit(%{"domain" => "acme.de", "method" => "dns"})

      second = Enum.find(Companies.list_domains(company), &(&1.domain == "acme.de"))
      assert second

      # The inline verification panel shows the REAL TXT record, not the literal
      # `{@dns_value}` (a phx-no-curly-interpolation interpolation trap).
      html = render(view)
      assert html =~ "vutuv-verify=#{second.verification_token}"
      refute html =~ "@dns_value"

      stub_dns(second.verification_token)

      view |> element("#verify-#{second.id}") |> render_click()
      assert Companies.get_domain(company, second.id).verified_at

      # The re-rendered page now offers "Make primary" for the verified domain.
      render(view)
      view |> element("#domain-#{second.id} button", "Make primary") |> render_click()
      assert Companies.primary_domain(company).domain == "acme.de"
    end

    test "removing the last verified domain is refused", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      company = active_company_for(owner)
      primary = Companies.primary_domain(company)

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.slug}/domains")
      html = view |> element("#domain-#{primary.id} button", "Remove") |> render_click()

      assert html =~ "at least one verified domain"
      assert Companies.primary_domain(company).id == primary.id
    end
  end

  describe "pending page verification panel (#929 regression)" do
    test "the owner's verify panel shows the real DNS token, not a literal assign", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)

      {:ok, %{company: company, domain: domain}} =
        Companies.create_pending_company(owner, @valid, "dns")

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.slug}")
      html = render(view)

      assert html =~ "vutuv-verify=#{domain.verification_token}"
      refute html =~ "@dns_value"
    end
  end

  describe "aliases on the edit page" do
    test "owner adds an alias and the page + agent formats list it", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      company = active_company_for(owner)

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.slug}/edit")

      view
      |> element("#add-alias-form")
      |> render_submit(%{"name" => "AcmeCorp", "kind" => "brand"})

      assert render(view) =~ "AcmeCorp"
      assert Enum.any?(Companies.list_aliases(company), &(&1.name == "AcmeCorp"))

      # The public page and its agent formats now show the alias.
      assert build_conn() |> get(~p"/companies/#{company.slug}") |> html_response(200) =~
               "AcmeCorp"

      assert build_conn() |> get("/companies/#{company.slug}.md") |> response(200) =~ "AcmeCorp"

      json =
        build_conn() |> get("/companies/#{company.slug}.json") |> response(200) |> Jason.decode!()

      assert Enum.any?(json["aliases"], &(&1["name"] == "AcmeCorp"))
    end
  end

  describe "admin dashboard" do
    test "an admin freezes and unfreezes a company", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      owner = insert(:activated_user)
      company = active_company_for(owner)

      {:ok, view, _html} = live(conn, ~p"/admin/companies")
      assert render(view) =~ company.name

      view |> element("#company-row-#{company.id} button", "Details") |> render_click()
      view |> element("#company-detail button", "Freeze") |> render_click()

      assert Companies.get_company(company.id).frozen_at
      # A frozen page 404s for the public.
      assert build_conn() |> get(~p"/companies/#{company.slug}") |> response(404)

      view |> element("#company-detail button", "Unfreeze") |> render_click()
      refute Companies.get_company(company.id).frozen_at
      assert build_conn() |> get(~p"/companies/#{company.slug}") |> html_response(200)
    end

    test "a non-admin cannot reach the dashboard", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert conn |> get(~p"/admin/companies") |> response(403)
    end
  end
end
