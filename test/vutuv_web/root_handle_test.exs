defmodule VutuvWeb.RootHandleTest do
  @moduledoc """
  Root-handle dispatch (issue #941): the URL root `/:handle` serves a member
  profile or an organization page from the shared handle namespace. Members keep the
  fast path (`users.username`); an organization that claimed a handle is reachable at
  `/:handle` exactly like `/organizations/:slug`, and its agent siblings work there
  too. Organization handles do NOT answer the member-only sub-pages.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Repo

  @valid %{
    "kind" => "company",
    "name" => "Lufthansa AG",
    "website_url" => "https://lufthansa.example",
    "street_address" => "Flughafen 1",
    "zip_code" => "60549",
    "city" => "Frankfurt",
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

  # An active, publicly visible organization that has claimed the root handle.
  defp organization_with_handle(handle) do
    owner = insert(:activated_user)

    {:ok, %{organization: organization, domain: domain}} =
      Organizations.create_pending_organization(owner, @valid, "dns")

    Application.put_env(:vutuv, :organizations_dns_resolver, fn _host ->
      [[~c"vutuv-organization-verify=#{domain.verification_token}"]]
    end)

    {:ok, organization} = Organizations.verify_dns(organization, domain)
    {:ok, organization} = Organizations.claim_handle(organization, %{"username" => handle})
    organization
  end

  describe "root handle dispatch" do
    test "an organization handle at the root serves the organization page", %{conn: conn} do
      organization = organization_with_handle("lufthansa")

      html = conn |> get("/lufthansa") |> html_response(200)
      assert html =~ organization.name
    end

    test "the root organization handle also serves the agent siblings", %{conn: conn} do
      organization = organization_with_handle("lufthansa")

      json = conn |> get("/lufthansa.json") |> response(200) |> Jason.decode!()
      assert json["name"] == organization.name

      md = conn |> get("/lufthansa.md") |> response(200)
      assert md =~ organization.name
    end

    test "a member handle at the root still serves the profile", %{conn: conn} do
      member = insert(:activated_user, username: "ada_member")

      html = conn |> get("/ada_member") |> html_response(200)
      assert html =~ member.username
    end

    test "an unclaimed handle 404s", %{conn: conn} do
      conn |> get("/nobody_here_at_all") |> html_response(404)
    end

    test "an organization handle does NOT answer the member-only sub-pages", %{conn: conn} do
      _organization = organization_with_handle("lufthansa")

      # /:handle/followers goes through the member pipeline (no organization
      # dispatch), so an organization handle is just an unknown member there.
      conn |> get("/lufthansa/followers") |> html_response(404)
    end

    test "the sitemap lists a handled organization at its canonical root URL", %{conn: _conn} do
      organization = organization_with_handle("lufthansa")

      paths = Vutuv.Sitemap.organization_entries(1) |> Enum.map(&elem(&1, 0))
      assert "/lufthansa" in paths
      refute "/organizations/#{organization.slug}" in paths
    end

    test "a frozen organization page is hidden at the root for the public", %{conn: conn} do
      organization = organization_with_handle("lufthansa")

      {:ok, _} =
        organization
        |> Organization.status_changeset("frozen")
        |> Ecto.Changeset.put_change(:frozen_at, NaiveDateTime.utc_now(:second))
        |> Repo.update()

      conn |> get("/lufthansa") |> html_response(404)
    end
  end
end
