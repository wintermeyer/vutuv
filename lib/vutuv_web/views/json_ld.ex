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
  alias Vutuv.Languages
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Organizations.OrganizationImage
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostReview
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

  @doc """
  The profile as ProfilePage/Person, from the show page's assigns.

  `extras` carries the rest of what the page already loaded (nothing here
  re-queries): `:followers` / `:posts` become the profile-page interaction
  statistics, `:educations` / `:languages` / `:qualifications` / `:addresses`
  enrich the Person entity with the cards the page shows, and the verified
  entries of `:urls` (the member proved the page is theirs,
  `Vutuv.Profiles.LinkVerification`) join `sameAs` as identity links.
  `dateCreated` / `dateModified` + the interaction counters are the fields
  search engines document for profile-page markup.
  """
  def person(user, job, user_tags, social_accounts, extras \\ %{}) do
    url = AgentDocs.abs_url("/" <> user.username)

    %{
      "@context" => "https://schema.org",
      "@type" => "ProfilePage",
      "dateCreated" => iso_utc(user.inserted_at),
      "dateModified" => iso_utc(user.updated_at),
      "mainEntity" =>
        compact(%{
          "@type" => "Person",
          "@id" => url,
          "name" => UserHelpers.full_name(user),
          "givenName" => user.first_name,
          "familyName" => user.last_name,
          "alternateName" => user.username,
          "identifier" => user.username,
          "description" => UserHelpers.headline_text(user.headline),
          "url" => url,
          "mainEntityOfPage" => url,
          "image" => ProfileDoc.avatar_url(user),
          "jobTitle" => job && UserHelpers.current_title(job),
          "worksFor" => works_for(job),
          "knowsAbout" => Enum.map(user_tags, &UserTag.name/1),
          "knowsLanguage" => Enum.map(extras[:languages] || [], &language_entity/1),
          "alumniOf" => extras[:educations] |> List.wrap() |> Enum.flat_map(&education_entity/1),
          "hasCredential" => Enum.map(extras[:qualifications] || [], &credential_entity/1),
          "address" =>
            extras[:addresses] |> List.wrap() |> Enum.flat_map(&member_postal_address/1),
          "interactionStatistic" => interaction_counter("FollowAction", extras[:followers]),
          "agentInteractionStatistic" => interaction_counter("WriteAction", extras[:posts]),
          "sameAs" =>
            Enum.map(social_accounts, &SocialMediaAccount.url/1) ++
              verified_link_urls(extras[:urls])
        })
    }
  end

  # ISO 8601 with an explicit UTC offset, the form the profile-page markup
  # expects (the naive timestamps are stored UTC).
  defp iso_utc(%NaiveDateTime{} = naive),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp language_entity(language) do
    compact(%{
      "@type" => "Language",
      "name" => Languages.name(language.language_code),
      "alternateName" => language.language_code
    })
  end

  defp education_entity(%{school: school}) when school in [nil, ""], do: []
  defp education_entity(edu), do: [%{"@type" => "EducationalOrganization", "name" => edu.school}]

  defp credential_entity(qualification) do
    compact(%{
      "@type" => "EducationalOccupationalCredential",
      "name" => qualification.name,
      "credentialCategory" => qualification.kind,
      "recognizedBy" =>
        qualification.issuer && %{"@type" => "Organization", "name" => qualification.issuer}
    })
  end

  # A member address as PostalAddress; an entry whose visible parts are all
  # empty (only a description like "Home") contributes nothing.
  defp member_postal_address(address) do
    street =
      [address.line_1, address.line_2, address.line_3, address.line_4]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(", ")

    entity =
      compact(%{
        "@type" => "PostalAddress",
        "streetAddress" => street,
        "postalCode" => address.zip_code,
        "addressLocality" => address.city,
        "addressRegion" => address.state,
        "addressCountry" => address.country
      })

    if map_size(entity) > 1, do: [entity], else: []
  end

  defp interaction_counter(_action, count) when count in [nil, 0], do: nil

  defp interaction_counter(action, count) do
    %{
      "@type" => "InteractionCounter",
      "interactionType" => "https://schema.org/" <> action,
      "userInteractionCount" => count
    }
  end

  defp verified_link_urls(urls) do
    urls |> List.wrap() |> Enum.filter(& &1.verified_at) |> Enum.map(& &1.value)
  end

  @doc "The permalink's post as a BlogPosting."
  def blog_posting(post, author) do
    permalink = AgentDocs.abs_url(Posts.path(post))
    author_url = AgentDocs.abs_url("/" <> author.username)

    compact(%{
      "@context" => "https://schema.org",
      # A post carrying a review sidecar is also a schema.org Review of the
      # book/movie it names (rich results pick the Review type up).
      "@type" => if(review_of(post), do: ["BlogPosting", "Review"], else: "BlogPosting"),
      "itemReviewed" => item_reviewed(review_of(post)),
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
      # Public structured data: only AI-released images.
      "image" => post |> Posts.released_images() |> Enum.map(&image_url/1),
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

  @doc """
  A visible `<.page_header>` crumbs trail as a schema.org BreadcrumbList:
  the site root first, then each crumb — linked crumbs (`{label, href}`)
  carry their absolute URL, a bare label (the current page, unlinked in the
  visible trail too) only its name, which schema.org allows for the final
  item.
  """
  def breadcrumb_trail(crumbs) do
    home = %{
      "@type" => "ListItem",
      "position" => 1,
      "item" => %{"@id" => VutuvWeb.Endpoint.url(), "name" => "vutuv"}
    }

    items =
      crumbs
      |> Enum.with_index(2)
      |> Enum.map(fn
        {{label, href}, position} ->
          %{
            "@type" => "ListItem",
            "position" => position,
            "item" => %{"@id" => crumb_url(href), "name" => to_string(label)}
          }

        {label, position} ->
          %{"@type" => "ListItem", "position" => position, "name" => to_string(label)}
      end)

    %{
      "@context" => "https://schema.org",
      "@type" => "BreadcrumbList",
      "itemListElement" => [home | items]
    }
  end

  defp crumb_url("http" <> _ = url), do: url
  defp crumb_url(path), do: AgentDocs.abs_url(path)

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

  defp review_of(%{review: %PostReview{} = review}), do: review
  defp review_of(_post), do: nil

  # The reviewed work as a schema.org Book/Movie. The medium maps onto
  # bookFormat where schema.org has a value for it (print stays unset — we
  # don't know hardcover vs. paperback).
  defp item_reviewed(nil), do: nil

  defp item_reviewed(%PostReview{kind: "book"} = review) do
    compact(%{
      # An audiobook is its own schema.org type (a subtype of Book), and the
      # one that carries a duration.
      "@type" => if(review.medium == "audiobook", do: "Audiobook", else: "Book"),
      "name" => review.title,
      "author" => review.creator,
      "isbn" => review.identifier,
      "datePublished" => review.year && Integer.to_string(review.year),
      "numberOfPages" => review.pages,
      "duration" => iso_duration(review.duration_minutes),
      "publisher" => publisher(review.publisher),
      "bookFormat" => book_format(review.medium)
    })
  end

  defp item_reviewed(%PostReview{kind: "movie"} = review) do
    compact(%{
      "@type" => "Movie",
      "name" => review.title,
      "director" => review.creator,
      "sameAs" => PostReview.imdb_url(review),
      "datePublished" => review.year && Integer.to_string(review.year)
    })
  end

  defp item_reviewed(%PostReview{}), do: nil

  # schema.org wants the publisher as an Organization, not a bare string.
  defp publisher(nil), do: nil
  defp publisher(name), do: %{"@type" => "Organization", "name" => name}

  # A running time in whole minutes as the ISO 8601 duration schema.org reads
  # ("PT7H20M", "PT45M").
  defp iso_duration(total) when is_integer(total) and total > 0 do
    case {div(total, 60), rem(total, 60)} do
      {0, minutes} -> "PT#{minutes}M"
      {hours, 0} -> "PT#{hours}H"
      {hours, minutes} -> "PT#{hours}H#{minutes}M"
    end
  end

  defp iso_duration(_other), do: nil

  defp book_format("ebook"), do: "https://schema.org/EBook"
  defp book_format("audiobook"), do: "https://schema.org/AudiobookFormat"
  defp book_format(_other), do: nil
end
