defmodule VutuvWeb.AgentDocs.OrganizationDoc do
  @moduledoc """
  The agent-format doc builders for verified organization pages (issue #929): one
  organization (`/organizations/:slug`) and the directory (`/organizations`). Every public
  fact the HTML page shows must appear here too, in Markdown / plain text /
  JSON / XML (`agent_docs_drift_test.exs` enforces it). Only active, `geo?`
  organizations reach these builders (the controller 404s the rest), so a doc is
  always the anonymous public view of a real page.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Countries
  alias Vutuv.Jobs
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.JobPostingDoc
  alias VutuvWeb.UserHelpers

  @doc """
  One organization page, self-loading (the `ProfileDoc.build/2` convention):
  the verified domains, the aliases, the People section (the public-listing
  set of issue #931, crawl-capped at 200 with the true total carried in
  `people_total`) and the live public postings ("Offene Stellen", #933). One
  assembly shared by the public agent formats and `/api/2.0`, so a new doc
  section reaches both or neither.
  """
  def build_show(organization) do
    build_show(
      organization,
      Organizations.verified_domains(organization),
      Organizations.list_aliases(organization),
      Organizations.organization_people_page(organization, limit: 200).entries,
      Organizations.organization_people_count(organization),
      Jobs.list_organization_postings(organization, limit: 200).entries
    )
  end

  @doc """
  The pre-loaded-pieces form of `build_show/1`. `people` are the linked members
  the organization's People section shows (issue #931), already gated to the
  public-listing set; `people_total` is the full count the HTML page displays.
  """
  def build_show(
        organization,
        domains,
        aliases,
        people,
        people_total,
        open_positions
      ) do
    AgentDocs.doc_meta("organization", canonical_path(organization),
      noindex: not organization.seo?,
      noai: not organization.geo?
    )
    |> Map.merge(%{
      title: organization.name,
      description: organization.description,
      name: organization.name,
      kind: Organization.kind_label(organization.kind),
      slug: organization.slug,
      website_url: organization.website_url,
      verified_domains: Enum.map(domains, & &1.domain),
      primary_domain: primary_domain(domains),
      aliases: Enum.map(aliases, &%{name: &1.name, kind: &1.kind}),
      also_known_as: Enum.map(aliases, & &1.name),
      city: organization.city,
      country: organization.country,
      country_name: Countries.name(organization.country),
      address_line: address_line(organization),
      people_total: people_total,
      people: Enum.map(people, &person_entry/1),
      open_positions: Enum.map(open_positions, &JobPostingDoc.summary/1)
    })
  end

  defp person_entry(%{user: user, title: title, current?: current?}) do
    %{
      name: UserHelpers.full_name(user),
      title: title,
      current: current?,
      url: AgentDocs.abs_url("/" <> user.username)
    }
  end

  @doc "The directory of verified organization pages."
  def build_index(entries, total) do
    AgentDocs.doc_meta("organizations", "/organizations")
    |> Map.merge(%{
      title: gettext("Organizations"),
      description: gettext("Verified organization pages on vutuv."),
      total: total,
      organizations:
        Enum.map(entries, fn organization ->
          %{
            name: organization.name,
            kind: Organization.kind_label(organization.kind),
            city: organization.city,
            country: Countries.name(organization.country),
            url: AgentDocs.abs_url(canonical_path(organization))
          }
        end)
    })
  end

  # An organization that claimed a root handle (issue #941) is canonical at
  # `/:handle`; the agent docs point there too, matching the HTML rel=canonical
  # and the sitemap. Shared with the profile link + sitemap via the context.
  defp canonical_path(organization), do: Organizations.canonical_path(organization)

  defp primary_domain(domains) do
    case Enum.find(domains, & &1.primary?) || List.first(domains) do
      nil -> nil
      domain -> domain.domain
    end
  end

  # "Street, 50667 City, State, Country" — nil parts folded away (street and
  # postal code are optional, so the "zip city" segment drops a missing zip too).
  defp address_line(organization) do
    [
      organization.street_address,
      [organization.zip_code, organization.city] |> Enum.reject(&blank?/1) |> Enum.join(" "),
      organization.state,
      Countries.name(organization.country)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(", ")
  end

  defp blank?(value), do: value in [nil, ""]
end
