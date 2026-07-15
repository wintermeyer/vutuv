defmodule Vutuv.OrganizationsHelpers do
  @moduledoc """
  Test helpers for verified organization pages (issues #929/#930), the
  sibling of `Vutuv.JobsHelpers`: the baseline valid attrs, the DNS-resolver
  stub, and the one-call "create pending → stub DNS → verify" pipeline that a
  third of the organization tests used to hand-roll — when the verification
  flow changes shape (as it did for #930 multi-domain), this is the one place
  to follow.

  Callers keep their own `setup` for the `:verify_organization_domains` flag
  and its `on_exit` cleanup (some files also stub the well-known HTTP path).
  """

  import Vutuv.Factory

  alias Vutuv.Organizations

  @valid_attrs %{
    "kind" => "company",
    "name" => "Acme GmbH",
    "website_url" => "https://acme.example",
    "street_address" => "Hauptstrasse 1",
    "zip_code" => "50667",
    "city" => "Köln",
    "country" => "DE"
  }

  @doc "The baseline valid organization attrs, merged with `overrides`."
  def valid_organization_attrs(overrides \\ %{}), do: Map.merge(@valid_attrs, overrides)

  @doc "Points the DNS resolver stub at `token`, so `verify_dns/2` succeeds."
  def stub_dns(token) do
    Application.put_env(:vutuv, :organizations_dns_resolver, fn _host ->
      [[~c"vutuv-organization-verify=#{token}"]]
    end)
  end

  @doc """
  A fresh activated owner with an active (DNS-verified) organization page.
  Returns `{organization, owner}`.
  """
  def active_organization(overrides \\ %{}) do
    owner = insert(:activated_user)
    {active_organization_for(owner, overrides), owner}
  end

  @doc "An active (DNS-verified) organization page owned by `owner`."
  def active_organization_for(owner, overrides \\ %{}) do
    {:ok, %{organization: organization, domain: domain}} =
      Organizations.create_pending_organization(owner, valid_organization_attrs(overrides), "dns")

    stub_dns(domain.verification_token)
    {:ok, organization} = Organizations.verify_dns(organization, domain)
    organization
  end
end
