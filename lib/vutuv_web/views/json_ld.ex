defmodule VutuvWeb.JsonLd do
  @moduledoc """
  schema.org JSON-LD for the public pages: ProfilePage/Person on profiles,
  BlogPosting on post permalinks, WebSite (with SearchAction) and
  Organization on the homepage, BreadcrumbList where pages carry one.

  `script/1` is the single emitter — every block encodes with
  `escape: :html_safe` so member-written content can never break out of
  the `<script>` element (see json_ld_xss_test.exs). Builders work from
  the **already-loaded page assigns**, not the AgentDocs doc builders
  (which would re-run their preloads on the hottest pages); the anti-drift
  guarantee is json_ld_test.exs comparing the output against
  ProfileDoc/PostDoc.

  Markup mirrors what the page shows (schema.org's accuracy rule), so a
  noindexed member's profile carries no Person block — gate at the call
  site. robots.txt disallows /search for crawlers; the SearchAction stays
  correct regardless: agents execute the URL template, they do not crawl
  it.
  """

  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Organizations.OrganizationImage
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Tags.UserTag
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.UserHelpers

  attr(:data, :map, required: true)

  def script(assigns) do
    ~H"""
    <script type="application/ld+json">
      <%= raw(Jason.encode!(@data, escape: :html_safe, pretty: true)) %>
    </script>
    """
  end

  def organization do
    %{
      "@context" => "https://schema.org",
      "@type" => "Organization",
      "name" => "vutuv",
      "url" => VutuvWeb.Endpoint.url()
    }
  end

  @doc """
  A verified organization page as schema.org Organization (issue #929), from the show
  page's assigns. Gate at the call site: only emit for an indexable page.
  """
  def organization_page(organization, verified_domains) do
    url = AgentDocs.abs_url("/organizations/#{organization.slug}")

    compact(%{
      "@context" => "https://schema.org",
      "@type" => Organization.schema_org_type(organization.kind),
      "@id" => url,
      "name" => organization.name,
      "url" => url,
      "logo" => organization_logo_url(organization),
      "sameAs" => organization_same_as(organization, verified_domains),
      "address" => postal_address(organization)
    })
  end

  defp organization_logo_url(%{logo: nil}), do: nil

  defp organization_logo_url(%{logo: token}),
    do: AgentDocs.abs_url(OrganizationImage.token_url(token, "large"))

  defp organization_same_as(organization, verified_domains) do
    domain_urls = Enum.map(verified_domains, &("https://" <> &1.domain))

    [organization.website_url | domain_urls]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp postal_address(organization) do
    compact(%{
      "@type" => "PostalAddress",
      "streetAddress" => organization.street_address,
      "postalCode" => organization.zip_code,
      "addressLocality" => organization.city,
      "addressRegion" => organization.state,
      "addressCountry" => organization.country
    })
  end

  def web_site do
    %{
      "@context" => "https://schema.org",
      "@type" => "WebSite",
      "name" => "vutuv",
      # No `www.` alternate name: the site has one canonical host (the bare
      # PHX_HOST, e.g. vutuv.de) and `www.` 301-redirects to it. Advertising
      # `www.<host>` as a schema.org alias was the one spot in the whole app that
      # told crawlers the www form is a real name for the site, which kept it
      # surfacing in search results against the canonical signal — and it is wrong
      # for an installation whose host has no `www.` sibling (an intranet host).
      "url" => VutuvWeb.Endpoint.url(),
      "potentialAction" => %{
        "@type" => "SearchAction",
        "target" => %{
          "@type" => "EntryPoint",
          "urlTemplate" => AgentDocs.abs_url("/search?q={search_term_string}")
        },
        "query-input" => "required name=search_term_string"
      }
    }
  end

  @doc "The profile as ProfilePage/Person, from the show page's assigns."
  def person(user, job, user_tags, social_accounts) do
    url = AgentDocs.abs_url("/" <> user.username)

    %{
      "@context" => "https://schema.org",
      "@type" => "ProfilePage",
      "mainEntity" =>
        compact(%{
          "@type" => "Person",
          "@id" => url,
          "name" => UserHelpers.full_name(user),
          "givenName" => user.first_name,
          "familyName" => user.last_name,
          "url" => url,
          "image" => ProfileDoc.avatar_url(user),
          "jobTitle" => job && UserHelpers.current_title(job),
          "worksFor" => works_for(job),
          "knowsAbout" => Enum.map(user_tags, &UserTag.name/1),
          "sameAs" => Enum.map(social_accounts, &SocialMediaAccount.url/1)
        })
    }
  end

  @doc "The permalink's post as a BlogPosting."
  def blog_posting(post, author) do
    permalink = AgentDocs.abs_url(Posts.path(post))
    author_url = AgentDocs.abs_url("/" <> author.username)

    compact(%{
      "@context" => "https://schema.org",
      "@type" => "BlogPosting",
      "@id" => permalink,
      "headline" => "#{UserHelpers.full_name(author)} · #{Date.to_iso8601(post.published_on)}",
      "datePublished" => Date.to_iso8601(post.published_on),
      "dateModified" => post.updated_at |> NaiveDateTime.to_date() |> Date.to_iso8601(),
      "author" => %{
        "@type" => "Person",
        "@id" => author_url,
        "name" => UserHelpers.full_name(author),
        "url" => author_url
      },
      "articleBody" => post.body,
      "keywords" => Enum.map(post.tags, & &1.name),
      "image" => Enum.map(post.images, &image_url/1),
      "mainEntityOfPage" => permalink
    })
  end

  @doc """
  A published job posting as schema.org JobPosting (issue #932), from the detail
  page's assigns. Gate at the call site: only emit for an indexable posting.
  """
  def job_posting(%JobPosting{} = posting) do
    url = AgentDocs.abs_url("/jobs/#{posting.slug}")

    compact(
      %{
        "@context" => "https://schema.org",
        "@type" => "JobPosting",
        "@id" => url,
        "url" => url,
        "title" => posting.title,
        "description" => posting.description,
        "datePosted" => AgentDocs.iso_date(posting.first_published_at),
        "validThrough" => posting.expires_on && Date.to_iso8601(posting.expires_on),
        "employmentType" => JobPosting.schema_org_employment_type(posting.employment_type),
        "hiringOrganization" => hiring_organization(posting),
        "identifier" => %{"@type" => "PropertyValue", "name" => "vutuv", "value" => posting.id},
        "skills" => job_skills(posting),
        "directApply" => posting.apply_kind == :message
      }
      |> Map.merge(job_location_fields(posting))
      |> Map.merge(base_salary(posting))
    )
  end

  # Search engines require applicantLocationRequirements (and no jobLocation) for
  # a fully-remote posting; a Place/PostalAddress for onsite and hybrid.
  defp job_location_fields(%JobPosting{workplace_type: :remote} = posting) do
    %{
      "jobLocationType" => "TELECOMMUTE",
      "applicantLocationRequirements" =>
        Enum.map(posting.remote_countries, &%{"@type" => "Country", "name" => &1})
    }
  end

  defp job_location_fields(%JobPosting{} = posting) do
    %{
      "jobLocation" => %{
        "@type" => "Place",
        "address" =>
          compact(%{
            "@type" => "PostalAddress",
            "streetAddress" => posting.street_address,
            "postalCode" => posting.zip_code,
            "addressLocality" => posting.city,
            "addressCountry" => posting.country
          })
      }
    }
  end

  defp base_salary(%JobPosting{employment_type: :volunteer}), do: %{}
  defp base_salary(%JobPosting{salary_min: nil}), do: %{}

  defp base_salary(%JobPosting{} = posting) do
    %{
      "baseSalary" => %{
        "@type" => "MonetaryAmount",
        "currency" => posting.salary_currency,
        "value" =>
          compact(%{
            "@type" => "QuantitativeValue",
            "minValue" => posting.salary_min,
            "maxValue" => posting.salary_max,
            "unitText" => String.upcase(posting.salary_period)
          })
      }
    }
  end

  defp hiring_organization(%JobPosting{organization: %Organization{} = org}) do
    url = AgentDocs.abs_url(Organizations.canonical_path(org))

    compact(%{
      "@type" => Organization.schema_org_type(org.kind),
      "name" => org.name,
      "url" => url,
      "logo" => organization_logo_url(org)
    })
  end

  defp hiring_organization(%JobPosting{hiring_org_name: name}) when is_binary(name),
    do: %{"@type" => "Organization", "name" => name}

  defp hiring_organization(%JobPosting{user: user}) do
    url = AgentDocs.abs_url("/" <> user.username)
    %{"@type" => "Person", "name" => UserHelpers.full_name(user), "url" => url}
  end

  # Required tags first (they weigh more in matching), then nice-to-have.
  defp job_skills(%JobPosting{} = posting) do
    (Jobs.tags_of(posting, :required) ++ Jobs.tags_of(posting, :nice_to_have))
    |> Enum.map(& &1.name)
  end

  def breadcrumbs(user) do
    profile_url = AgentDocs.abs_url("/" <> user.username)

    %{
      "@context" => "https://schema.org",
      "@type" => "BreadcrumbList",
      "itemListElement" => [
        %{
          "@type" => "ListItem",
          "position" => 1,
          "item" => %{"@id" => VutuvWeb.Endpoint.url(), "name" => "vutuv"}
        },
        %{
          "@type" => "ListItem",
          "position" => 2,
          "item" => %{"@id" => profile_url, "name" => UserHelpers.full_name(user)}
        }
      ]
    }
  end

  defp works_for(nil), do: nil

  defp works_for(job) do
    case UserHelpers.current_organization(job) do
      # The helpers answer "" for absent data; absent markup, not "".
      "" -> nil
      organization -> %{"@type" => "Organization", "name" => organization}
    end
  end

  defp image_url(image) do
    case PostImage.url(image, "large") do
      "/" <> _ = path -> AgentDocs.abs_url(path)
      url -> url
    end
  end

  # schema.org consumers treat absent and null alike; empty lists and
  # strings carry no information either — drop them all so the markup
  # stays honest and small.
  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, [], ""] end)
    |> Map.new()
  end
end
