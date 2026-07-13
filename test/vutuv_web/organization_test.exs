defmodule VutuvWeb.OrganizationTest do
  @moduledoc """
  The verified-organization web surface (issue #929): the directory + page and their
  agent-format siblings, the claim wizard + domain verification, engagement and
  the moderation report path. `async: false` because verification flips the
  global `:verify_organization_domains` flag and injects a DNS resolver.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Vutuv.Jobs
  alias Vutuv.JobsHelpers
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
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

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp active_organization(attrs \\ %{}) do
    owner = insert(:activated_user)
    merged = Map.merge(@valid, attrs)

    {:ok, %{organization: organization, domain: domain}} =
      Organizations.create_pending_organization(owner, merged, "dns")

    Application.put_env(:vutuv, :organizations_dns_resolver, fn _host ->
      [[~c"vutuv-organization-verify=#{domain.verification_token}"]]
    end)

    {:ok, organization} = Organizations.verify_dns(organization, domain)
    {organization, owner}
  end

  describe "directory" do
    test "renders active organizations and serves agent formats", %{conn: conn} do
      {organization, _owner} = active_organization()

      html = conn |> get(~p"/organizations") |> html_response(200)
      assert html =~ organization.name

      json = conn |> get(~p"/organizations.json") |> response(200) |> Jason.decode!()
      assert json["type"] == "organizations"
      assert Enum.any?(json["organizations"], &(&1["name"] == organization.name))

      md = conn |> get(~p"/organizations.md") |> response(200)
      assert md =~ organization.name
    end
  end

  describe "organization page" do
    test "shows the same facts in HTML and every agent format", %{conn: conn} do
      {organization, _owner} = active_organization()
      path = ~p"/organizations/#{organization.slug}"

      for {format, ext} <- [
            {"html", ""},
            {"md", ".md"},
            {"txt", ".txt"},
            {"json", ".json"},
            {"xml", ".xml"}
          ] do
        body = conn |> get(path <> ext) |> response(200)

        assert String.downcase(body) =~ String.downcase(organization.name),
               "name missing from #{format}"

        assert String.downcase(body) =~ "acme.example", "verified domain missing from #{format}"
      end

      json = conn |> get(path <> ".json") |> response(200) |> Jason.decode!()
      assert json["type"] == "organization"
      assert json["city"] == "Köln"
    end

    test "emits kind-typed JSON-LD on the HTML page", %{conn: conn} do
      {organization, _owner} = active_organization()
      html = conn |> get(~p"/organizations/#{organization.slug}") |> html_response(200)
      # A company maps to schema.org Corporation (a Behörde would be a
      # GovernmentOrganization, a university an EducationalOrganization).
      assert html =~ ~s("@type": "Corporation")
      assert html =~ ~s("@type": "PostalAddress")
    end

    test "geo? off makes the agent siblings 404 but still renders HTML", %{conn: conn} do
      {organization, _owner} = active_organization()
      {:ok, _} = Organizations.update_organization(organization, %{"geo?" => false})

      assert conn |> get(~p"/organizations/#{organization.slug}") |> html_response(200)
      assert conn |> get("/organizations/#{organization.slug}.md") |> response(404)
    end

    test "seo? off marks the doc noindex", %{conn: conn} do
      {organization, _owner} = active_organization()
      {:ok, _} = Organizations.update_organization(organization, %{"seo?" => false})

      md = conn |> get("/organizations/#{organization.slug}.md") |> response(200)
      assert md =~ "noindex: true"
    end

    test "a pending organization is 404 for the public in every format", %{conn: conn} do
      owner = insert(:activated_user)

      {:ok, %{organization: organization}} =
        Organizations.create_pending_organization(owner, @valid, "dns")

      assert conn |> get(~p"/organizations/#{organization.slug}") |> response(404)
      assert conn |> get("/organizations/#{organization.slug}.json") |> response(404)
    end
  end

  describe "claim wizard" do
    test "the page explains why we verify and points non-technical members at their admin",
         %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, _view, html} = live(conn, ~p"/organizations/new")

      # The friendly heading, not the old "Claim an organization" jargon.
      assert html =~ "Add your organization"
      refute html =~ "Claim an organization"
      # Why verification exists at all, and who to ask for the technical step.
      assert html =~ "trust the page"
      assert html =~ "IT department"
      assert html =~ "the next step"
    end

    test "creates a pending organization and lands on the verification panel", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      assert view
             |> form("#organization-form",
               organization: %{
                 name: "Widgets Inc",
                 kind: "association",
                 website_url: "https://widgets.example",
                 street_address: "Market St 5",
                 zip_code: "94105",
                 city: "San Francisco",
                 country: "US"
               }
             )
             |> render_submit()

      assert_redirect(view, ~p"/organizations/widgets-inc")
      organization = Organizations.get_organization_by_slug("widgets-inc")
      assert organization.status == "pending"
      assert organization.kind == :association
    end
  end

  describe "domain verification" do
    test "the owner verifies from the pending page and the operator is alerted", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, %{organization: organization, domain: domain}} =
        Organizations.create_pending_organization(user, @valid, "dns")

      Application.put_env(:vutuv, :organizations_dns_resolver, fn _host ->
        [[~c"vutuv-organization-verify=#{domain.verification_token}"]]
      end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}")
      assert has_element?(view, "#verify-domain")

      view |> element("#verify-domain") |> render_click()

      assert Repo.get!(Organization, organization.id).status == "active"
      assert_email_sent(fn email -> assert email.subject =~ "verifiziert" end)
    end
  end

  describe "engagement" do
    test "a signed-in member likes and bookmarks the page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {organization, _owner} = active_organization()

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}")
      view |> element("button[phx-click='toggle_like']") |> render_click()
      view |> element("button[phx-click='toggle_bookmark']") |> render_click()

      assert Organizations.organization_engagement(organization, user).likes == 1
      assert [saved] = Organizations.bookmarked_organizations(user)
      assert saved.id == organization.id
    end
  end

  describe "open positions (#933)" do
    test "the organization page lists its live public postings", %{conn: conn} do
      {organization, owner} = active_organization()
      owner = backdate(owner)

      {:ok, draft} =
        Jobs.create_draft(owner, %{"title" => "Open role at org"}, organization: organization)

      {:ok, _posting} =
        Jobs.publish(draft, owner, JobsHelpers.job_attrs(%{"title" => "Open role at org"}),
          organization: organization
        )

      {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.slug}")

      assert html =~ "Open positions"
      assert html =~ "Open role at org"
    end
  end

  # Age the account past the publish gate (a confirmed account >= 3 days old).
  defp backdate(user) do
    old = NaiveDateTime.add(NaiveDateTime.utc_now(), -5 * 86_400, :second)
    query = from(u in Vutuv.Accounts.User, where: u.id == ^user.id)
    Repo.update_all(query, set: [inserted_at: old])
    Repo.reload!(user)
  end

  describe "moderation" do
    test "reporting an organization opens a moderation case", %{conn: conn} do
      {conn, _reporter} = create_and_login_user(conn)
      {organization, _owner} = active_organization()

      conn =
        post(conn, ~p"/reports", %{
          "report" => %{
            "type" => "organization",
            "id" => organization.id,
            "return_to" => "/organizations/#{organization.slug}",
            "category" => "spam"
          }
        })

      assert redirected_to(conn) =~ "/organizations/#{organization.slug}"

      assert Repo.exists?(
               Ecto.Query.from(c in Vutuv.Moderation.Case,
                 where: c.content_type == "organization" and c.content_id == ^organization.id
               )
             )
    end
  end
end
