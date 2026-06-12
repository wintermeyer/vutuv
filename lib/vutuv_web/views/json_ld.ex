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

  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
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

  def web_site do
    %{
      "@context" => "https://schema.org",
      "@type" => "WebSite",
      "name" => "vutuv",
      "alternateName" => "www.vutuv.de",
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
    url = AgentDocs.abs_url("/" <> user.active_slug)

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
          "sameAs" => Enum.map(social_accounts, &Vutuv.Profiles.SocialMediaAccount.url/1)
        })
    }
  end

  @doc "The permalink's post as a BlogPosting."
  def blog_posting(post, author) do
    permalink = AgentDocs.abs_url(Posts.path(post))
    author_url = AgentDocs.abs_url("/" <> author.active_slug)

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

  def breadcrumbs(user) do
    profile_url = AgentDocs.abs_url("/" <> user.active_slug)

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
