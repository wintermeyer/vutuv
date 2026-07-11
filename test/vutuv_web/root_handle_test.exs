defmodule VutuvWeb.RootHandleTest do
  @moduledoc """
  Root-handle dispatch (issue #941): the URL root `/:handle` serves a member
  profile or a company page from the shared handle namespace. Members keep the
  fast path (`users.username`); a company that claimed a handle is reachable at
  `/:handle` exactly like `/companies/:slug`, and its agent siblings work there
  too. Company handles do NOT answer the member-only sub-pages.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Companies
  alias Vutuv.Companies.Company
  alias Vutuv.Repo

  @valid %{
    "name" => "Lufthansa AG",
    "website_url" => "https://lufthansa.example",
    "street_address" => "Flughafen 1",
    "zip_code" => "60549",
    "city" => "Frankfurt",
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

  # An active, publicly visible company that has claimed the root handle.
  defp company_with_handle(handle) do
    owner = insert(:activated_user)

    {:ok, %{company: company, domain: domain}} =
      Companies.create_pending_company(owner, @valid, "dns")

    Application.put_env(:vutuv, :companies_dns_resolver, fn _host ->
      [[~c"vutuv-verify=#{domain.verification_token}"]]
    end)

    {:ok, company} = Companies.verify_dns(company, domain)
    {:ok, company} = Companies.claim_handle(company, %{"username" => handle})
    company
  end

  describe "root handle dispatch" do
    test "a company handle at the root serves the company page", %{conn: conn} do
      company = company_with_handle("lufthansa")

      html = conn |> get("/lufthansa") |> html_response(200)
      assert html =~ company.name
    end

    test "the root company handle also serves the agent siblings", %{conn: conn} do
      company = company_with_handle("lufthansa")

      json = conn |> get("/lufthansa.json") |> response(200) |> Jason.decode!()
      assert json["name"] == company.name

      md = conn |> get("/lufthansa.md") |> response(200)
      assert md =~ company.name
    end

    test "a member handle at the root still serves the profile", %{conn: conn} do
      member = insert(:activated_user, username: "ada_member")

      html = conn |> get("/ada_member") |> html_response(200)
      assert html =~ member.username
    end

    test "an unclaimed handle 404s", %{conn: conn} do
      conn |> get("/nobody_here_at_all") |> html_response(404)
    end

    test "a company handle does NOT answer the member-only sub-pages", %{conn: conn} do
      _company = company_with_handle("lufthansa")

      # /:handle/followers goes through the member pipeline (no company
      # dispatch), so a company handle is just an unknown member there.
      conn |> get("/lufthansa/followers") |> html_response(404)
    end

    test "the sitemap lists a handled company at its canonical root URL", %{conn: _conn} do
      company = company_with_handle("lufthansa")

      paths = Vutuv.Sitemap.company_entries(1) |> Enum.map(&elem(&1, 0))
      assert "/lufthansa" in paths
      refute "/companies/#{company.slug}" in paths
    end

    test "a frozen company page is hidden at the root for the public", %{conn: conn} do
      company = company_with_handle("lufthansa")

      {:ok, _} =
        company
        |> Company.status_changeset("frozen")
        |> Ecto.Changeset.put_change(:frozen_at, NaiveDateTime.utc_now(:second))
        |> Repo.update()

      conn |> get("/lufthansa") |> html_response(404)
    end
  end
end
