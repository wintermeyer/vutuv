defmodule VutuvWeb.JsonLdTest do
  @moduledoc """
  The JSON-LD blocks (VutuvWeb.JsonLd): Person/ProfilePage on profiles,
  BlogPosting on permalinks, WebSite + SearchAction on the homepage. The
  markup is built from the page assigns (not the doc builders — that
  would double the DB work), so these tests pin it against
  ProfileDoc/PostDoc output: the same anti-drift contract the agent
  formats have.
  """

  use VutuvWeb.ConnCase

  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias VutuvWeb.AgentDocs.PostDoc
  alias VutuvWeb.AgentDocs.ProfileDoc

  defp ld_blocks(html) do
    ~r|<script type="application/ld\+json">\s*(.+?)\s*</script>|s
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&Jason.decode!/1)
  end

  defp find_type(blocks, type), do: Enum.find(blocks, &(&1["@type"] == type))

  describe "profile page" do
    test "embeds a Person mirroring the profile doc" do
      user =
        insert_activated_user(
          username: "ld_member",
          first_name: "Lara",
          headline: "Builds **reliable** systems"
        )

      insert(:work_experience,
        user: user,
        title: "Engineer",
        organization: "Acme Corp",
        start_year: 2020,
        end_month: nil,
        end_year: nil
      )

      insert(:social_media_account, user: user, provider: "GitHub", value: "lara")
      tag = insert(:tag, name: "Elixir", slug: "elixir-ld")
      insert(:user_tag, user: user, tag: tag)

      html = build_conn() |> get("/ld_member") |> html_response(200)
      doc = ProfileDoc.build(user)

      page = html |> ld_blocks() |> find_type("ProfilePage")
      assert page, "expected a ProfilePage JSON-LD block"
      person = page["mainEntity"]

      assert person["@type"] == "Person"
      assert person["name"] == doc.name
      assert person["givenName"] == doc.first_name
      assert person["familyName"] == doc.last_name
      assert person["url"] == doc.url
      assert person["@id"] == doc.url
      assert person["jobTitle"] == doc.current_position.title
      assert person["worksFor"]["name"] == doc.current_position.organization
      assert Map.get(person, "image") == doc.avatar_url
      assert person["knowsAbout"] == ["Elixir"]
      assert person["sameAs"] == Enum.map(doc.social_media, & &1.url)
      # Google's profile-page markup: the handle and a plain-text headline.
      assert person["alternateName"] == "ld_member"
      assert person["identifier"] == "ld_member"
      assert person["description"] == "Builds reliable systems"
      assert person["mainEntityOfPage"] == doc.url
    end

    test "carries the profile-page dates and interaction statistics" do
      user = insert_activated_user(username: "ld_stats", first_name: "Stat")
      follow!(insert_activated_user(), user)
      create_post!(user, %{body: "First post"})

      html = build_conn() |> get("/ld_stats") |> html_response(200)

      page = html |> ld_blocks() |> find_type("ProfilePage")
      assert page

      db_user = Vutuv.Repo.get!(Vutuv.Accounts.User, user.id)

      assert page["dateCreated"] ==
               db_user.inserted_at
               |> DateTime.from_naive!("Etc/UTC")
               |> DateTime.to_iso8601()

      assert page["dateModified"] ==
               db_user.updated_at
               |> DateTime.from_naive!("Etc/UTC")
               |> DateTime.to_iso8601()

      person = page["mainEntity"]

      assert person["interactionStatistic"] == %{
               "@type" => "InteractionCounter",
               "interactionType" => "https://schema.org/FollowAction",
               "userInteractionCount" => 1
             }

      assert person["agentInteractionStatistic"] == %{
               "@type" => "InteractionCounter",
               "interactionType" => "https://schema.org/WriteAction",
               "userInteractionCount" => 1
             }
    end

    test "mirrors the education, language, credential, address and verified-link cards" do
      user = insert_activated_user(username: "ld_rich", first_name: "Rica")

      insert(:education, user: user, school: "TU Berlin", degree: "MSc")
      insert(:language, user: user, language_code: "de")
      insert(:qualification, user: user, name: "AWS Architect", issuer: "Amazon")
      insert(:address, user: user, city: "Bremen", country: "Germany")

      insert(:url,
        user: user,
        value: "https://rica.example",
        verified_at: NaiveDateTime.utc_now()
      )

      insert(:url, user: user, value: "https://unverified.example")

      person =
        build_conn()
        |> get("/ld_rich")
        |> html_response(200)
        |> ld_blocks()
        |> find_type("ProfilePage")
        |> Map.fetch!("mainEntity")

      assert person["alumniOf"] == [
               %{"@type" => "EducationalOrganization", "name" => "TU Berlin"}
             ]

      assert [%{"@type" => "Language", "alternateName" => "de", "name" => name}] =
               person["knowsLanguage"]

      assert name == Vutuv.Languages.name("de")

      assert [credential] = person["hasCredential"]
      assert credential["@type"] == "EducationalOccupationalCredential"
      assert credential["name"] == "AWS Architect"
      assert credential["recognizedBy"]["name"] == "Amazon"

      assert [address] = person["address"]
      assert address["@type"] == "PostalAddress"
      assert address["addressLocality"] == "Bremen"
      assert address["addressCountry"] == "Germany"

      # Only the proven-own webpage joins the identity links; the unverified
      # one stays out.
      assert "https://rica.example" in person["sameAs"]
      refute "https://unverified.example" in person["sameAs"]
    end

    test "keeps the BreadcrumbList next to the Person" do
      insert_activated_user(username: "ld_crumbs")

      blocks = build_conn() |> get("/ld_crumbs") |> html_response(200) |> ld_blocks()

      assert find_type(blocks, "BreadcrumbList")
    end

    test "a public section page carries a BreadcrumbList of its visible trail" do
      insert_activated_user(username: "ld_trail", first_name: "Tara", last_name: "Trail")

      crumbs =
        build_conn()
        |> get("/ld_trail/work_experiences")
        |> html_response(200)
        |> ld_blocks()
        |> find_type("BreadcrumbList")

      assert crumbs, "expected a BreadcrumbList JSON-LD block on the section page"

      items = crumbs["itemListElement"]
      assert Enum.any?(items, &(&1["item"]["@id"] == "http://localhost:4001/ld_trail"))
      # The trail ends on the section's own (unlinked) crumb.
      assert %{"name" => _} = List.last(items)
    end

    test "a noindexed member gets no Person markup" do
      insert_activated_user(username: "ld_quiet", noindex?: true)

      blocks = build_conn() |> get("/ld_quiet") |> html_response(200) |> ld_blocks()

      refute find_type(blocks, "ProfilePage")
    end
  end

  describe "post permalink" do
    test "embeds a BlogPosting mirroring the post doc" do
      author = insert_activated_user(username: "ld_author", first_name: "Pia")
      post = create_post!(author, %{body: "Hello **bold** world", tags: "elixir"})

      html = build_conn() |> get(Posts.path(post)) |> html_response(200)
      doc = PostDoc.build(author, post)

      posting = html |> ld_blocks() |> find_type("BlogPosting")
      assert posting, "expected a BlogPosting JSON-LD block"

      assert posting["headline"] == doc.title
      assert posting["articleBody"] == doc.body_markdown
      assert posting["datePublished"] == Date.to_iso8601(doc.published_on)
      assert posting["author"]["name"] == doc.author.name
      assert posting["author"]["url"] == doc.author.url
      assert posting["mainEntityOfPage"] == doc.url
      assert posting["keywords"] == doc.tags
    end

    test "a restricted post gets no BlogPosting markup" do
      author = insert_activated_user()

      post =
        create_post!(author, %{
          body: "members only",
          denials: [%{"wildcard" => "logged_out"}]
        })

      {member_conn, _member} =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> create_and_login_user()

      html = member_conn |> get(Posts.path(post)) |> html_response(200)

      refute html |> ld_blocks() |> find_type("BlogPosting")
    end
  end

  describe "homepage" do
    test "declares WebSite with a SearchAction and the Organization" do
      blocks = build_conn() |> get("/") |> html_response(200) |> ld_blocks()

      site = find_type(blocks, "WebSite")
      assert site["url"] == "http://localhost:4001"

      # The site has one canonical host: it must not advertise a `www.` alternate
      # name (that schema alias kept the www form alive in search results against
      # every canonical signal, and is wrong for a host with no www sibling).
      refute site["alternateName"]

      action = site["potentialAction"]
      assert action["@type"] == "SearchAction"
      assert action["target"]["urlTemplate"] =~ "/search?q={search_term_string}"

      org = find_type(blocks, "Organization")
      assert org["name"] == "vutuv"
      assert org["url"] == "http://localhost:4001"
    end
  end
end
