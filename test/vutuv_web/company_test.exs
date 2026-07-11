defmodule VutuvWeb.CompanyTest do
  @moduledoc """
  The verified-company web surface (issue #929): the directory + page and their
  agent-format siblings, the claim wizard + domain verification, engagement and
  the moderation report path. `async: false` because verification flips the
  global `:verify_company_domains` flag and injects a DNS resolver.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Vutuv.Companies
  alias Vutuv.Companies.Company
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

  defp active_company(attrs \\ %{}) do
    owner = insert(:activated_user)
    merged = Map.merge(@valid, attrs)

    {:ok, %{company: company, domain: domain}} =
      Companies.create_pending_company(owner, merged, "dns")

    Application.put_env(:vutuv, :companies_dns_resolver, fn _host ->
      [[~c"vutuv-company-verify=#{domain.verification_token}"]]
    end)

    {:ok, company} = Companies.verify_dns(company, domain)
    {company, owner}
  end

  describe "directory" do
    test "renders active companies and serves agent formats", %{conn: conn} do
      {company, _owner} = active_company()

      html = conn |> get(~p"/companies") |> html_response(200)
      assert html =~ company.name

      json = conn |> get(~p"/companies.json") |> response(200) |> Jason.decode!()
      assert json["type"] == "companies"
      assert Enum.any?(json["companies"], &(&1["name"] == company.name))

      md = conn |> get(~p"/companies.md") |> response(200)
      assert md =~ company.name
    end
  end

  describe "company page" do
    test "shows the same facts in HTML and every agent format", %{conn: conn} do
      {company, _owner} = active_company()
      path = ~p"/companies/#{company.slug}"

      for {format, ext} <- [
            {"html", ""},
            {"md", ".md"},
            {"txt", ".txt"},
            {"json", ".json"},
            {"xml", ".xml"}
          ] do
        body = conn |> get(path <> ext) |> response(200)

        assert String.downcase(body) =~ String.downcase(company.name),
               "name missing from #{format}"

        assert String.downcase(body) =~ "acme.example", "verified domain missing from #{format}"
      end

      json = conn |> get(path <> ".json") |> response(200) |> Jason.decode!()
      assert json["type"] == "company"
      assert json["city"] == "Köln"
    end

    test "emits Organization JSON-LD on the HTML page", %{conn: conn} do
      {company, _owner} = active_company()
      html = conn |> get(~p"/companies/#{company.slug}") |> html_response(200)
      assert html =~ ~s("@type": "Organization")
      assert html =~ ~s("@type": "PostalAddress")
    end

    test "geo? off makes the agent siblings 404 but still renders HTML", %{conn: conn} do
      {company, _owner} = active_company()
      {:ok, _} = Companies.update_company(company, %{"geo?" => false})

      assert conn |> get(~p"/companies/#{company.slug}") |> html_response(200)
      assert conn |> get("/companies/#{company.slug}.md") |> response(404)
    end

    test "seo? off marks the doc noindex", %{conn: conn} do
      {company, _owner} = active_company()
      {:ok, _} = Companies.update_company(company, %{"seo?" => false})

      md = conn |> get("/companies/#{company.slug}.md") |> response(200)
      assert md =~ "noindex: true"
    end

    test "a pending company is 404 for the public in every format", %{conn: conn} do
      owner = insert(:activated_user)
      {:ok, %{company: company}} = Companies.create_pending_company(owner, @valid, "dns")

      assert conn |> get(~p"/companies/#{company.slug}") |> response(404)
      assert conn |> get("/companies/#{company.slug}.json") |> response(404)
    end
  end

  describe "claim wizard" do
    test "creates a pending company and lands on the verification panel", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, view, _html} = live(conn, ~p"/companies/new")

      assert view
             |> form("#company-form",
               company: %{
                 name: "Widgets Inc",
                 website_url: "https://widgets.example",
                 street_address: "Market St 5",
                 zip_code: "94105",
                 city: "San Francisco",
                 country: "US"
               }
             )
             |> render_submit()

      assert_redirect(view, ~p"/companies/widgets-inc")
      company = Companies.get_company_by_slug("widgets-inc")
      assert company.status == "pending"
    end
  end

  describe "domain verification" do
    test "the owner verifies from the pending page and the operator is alerted", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, %{company: company, domain: domain}} =
        Companies.create_pending_company(user, @valid, "dns")

      Application.put_env(:vutuv, :companies_dns_resolver, fn _host ->
        [[~c"vutuv-company-verify=#{domain.verification_token}"]]
      end)

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.slug}")
      assert has_element?(view, "#verify-domain")

      view |> element("#verify-domain") |> render_click()

      assert Repo.get!(Company, company.id).status == "active"
      assert_email_sent(fn email -> assert email.subject =~ "verifiziert" end)
    end
  end

  describe "engagement" do
    test "a signed-in member likes and bookmarks the page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {company, _owner} = active_company()

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.slug}")
      view |> element("button[phx-click='toggle_like']") |> render_click()
      view |> element("button[phx-click='toggle_bookmark']") |> render_click()

      assert Companies.company_engagement(company, user).likes == 1
      assert [saved] = Companies.bookmarked_companies(user)
      assert saved.id == company.id
    end
  end

  describe "moderation" do
    test "reporting a company opens a moderation case", %{conn: conn} do
      {conn, _reporter} = create_and_login_user(conn)
      {company, _owner} = active_company()

      conn =
        post(conn, ~p"/reports", %{
          "report" => %{
            "type" => "company",
            "id" => company.id,
            "return_to" => "/companies/#{company.slug}",
            "category" => "spam"
          }
        })

      assert redirected_to(conn) =~ "/companies/#{company.slug}"

      assert Repo.exists?(
               Ecto.Query.from(c in Vutuv.Moderation.Case,
                 where: c.content_type == "company" and c.content_id == ^company.id
               )
             )
    end
  end
end
