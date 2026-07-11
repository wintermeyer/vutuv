defmodule VutuvWeb.AgentDocs.CompanyDoc do
  @moduledoc """
  The agent-format doc builders for verified company pages (issue #929): one
  company (`/companies/:slug`) and the directory (`/companies`). Every public
  fact the HTML page shows must appear here too, in Markdown / plain text /
  JSON / XML (`agent_docs_drift_test.exs` enforces it). Only active, `geo?`
  companies reach these builders (the controller 404s the rest), so a doc is
  always the anonymous public view of a real page.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Countries
  alias VutuvWeb.AgentDocs

  @doc "One company page."
  def build_show(company, domains, aliases \\ []) do
    AgentDocs.doc_meta("company", "/companies/#{company.slug}",
      noindex: not company.seo?,
      noai: not company.geo?
    )
    |> Map.merge(%{
      title: company.name,
      description: company.description,
      name: company.name,
      slug: company.slug,
      website_url: company.website_url,
      verified_domains: Enum.map(domains, & &1.domain),
      primary_domain: primary_domain(domains),
      aliases: Enum.map(aliases, &%{name: &1.name, kind: &1.kind}),
      also_known_as: Enum.map(aliases, & &1.name),
      city: company.city,
      country: company.country,
      country_name: Countries.name(company.country),
      address_line: address_line(company)
    })
  end

  @doc "The directory of verified company pages."
  def build_index(entries, total) do
    AgentDocs.doc_meta("companies", "/companies")
    |> Map.merge(%{
      title: gettext("Companies"),
      description: gettext("Verified company pages on vutuv."),
      total: total,
      companies:
        Enum.map(entries, fn company ->
          %{
            name: company.name,
            city: company.city,
            country: Countries.name(company.country),
            url: AgentDocs.abs_url("/companies/#{company.slug}")
          }
        end)
    })
  end

  defp primary_domain(domains) do
    case Enum.find(domains, & &1.primary?) || List.first(domains) do
      nil -> nil
      domain -> domain.domain
    end
  end

  # "Street, 50667 City, State, Country" — nil parts folded away.
  defp address_line(company) do
    [
      company.street_address,
      "#{company.zip_code} #{company.city}",
      company.state,
      Countries.name(company.country)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end
end
