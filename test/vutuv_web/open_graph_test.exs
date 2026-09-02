defmodule VutuvWeb.OpenGraphTest do
  @moduledoc """
  The link-preview head tags (Open Graph + twitter:card) that WhatsApp,
  Facebook, LinkedIn, Signal and X render when a vutuv URL is shared.
  `VutuvWeb.OpenGraph` derives one set per page from the conn assigns and
  the root layout renders it on every HTML page; these tests prove the
  wiring per page family. The brand fallback image is `VutuvWeb.OgCard`.
  """
  use VutuvWeb.ConnCase

  import Vutuv.OrganizationsHelpers
  import Vutuv.PostsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias VutuvWeb.OpenGraph

  @base "http://localhost:4001"

  defp og(html, property) do
    case Regex.run(~r/<meta property="#{Regex.escape(property)}" content="([^"]*)"/, html) do
      [_, content] -> content
      nil -> nil
    end
  end

  defp title(html) do
    [text] = Regex.run(~r|<title[^>]*>\s*(.*?)\s*</title>|s, html, capture: :all_but_first)
    text
  end

  # `og:locale` branched on German alone and answered `en_US` for everything
  # else, so an Italian page told Facebook and LinkedIn it was American English
  # while the same `<head>` rendered `<html lang="it">`. Every locale this
  # installation serves gets its own tag now — driven off `site_locales/0`, so a
  # fourth one fails here rather than silently reading as English.
  describe "og:locale follows the page's own language" do
    test "every served locale gets its own tag, and none of them says en_US by accident",
         %{conn: conn} do
      expected = %{"en" => "en_US", "de" => "de_DE", "it" => "it_IT"}

      for locale <- Vutuv.Languages.site_locales() do
        html =
          build_conn()
          |> put_req_header("accept-language", "#{locale}-#{String.upcase(locale)},#{locale}")
          |> get(~p"/")
          |> html_response(200)

        assert og(html, "og:locale") == Map.fetch!(expected, locale),
               "og:locale is wrong for #{locale}"

        assert html =~ ~s(<html lang="#{locale}"),
               "the page did not actually render in #{locale}"
      end

      assert conn
    end
  end

  describe "generic pages" do
    test "the landing page carries a full preview card", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert og(html, "og:site_name") == "vutuv"
      assert og(html, "og:type") == "website"
      assert og(html, "og:title") == "vutuv"
      # The landing page has no page-specific description, so it shows the
      # generic site pitch: a business network, no old "career network / no
      # premium accounts" line.
      assert og(html, "og:description") =~ "business network"
      refute og(html, "og:description") =~ "Career Network"
      refute og(html, "og:description") =~ "premium"
      assert og(html, "og:url") == @base <> "/"
      assert og(html, "og:image") == @base <> "/og-card.png"
      assert og(html, "og:image:width") == "1200"
      assert og(html, "og:image:height") == "630"
      assert html =~ ~s(<meta name="twitter:card" content="summary_large_image")
    end

    test "the plain description meta and og:description agree", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)

      [_, description] = Regex.run(~r/<meta name="description" content="([^"]*)"/, html)
      assert og(html, "og:description") == description
    end
  end

  describe "per-page descriptions" do
    test "public info pages carry their own description, not the site pitch", %{conn: conn} do
      cases = [
        {~p"/login", "Sign in to your vutuv account"},
        {~p"/community", "community guidelines"},
        {~p"/system/members", "member directory"},
        {~p"/nutzungsbedingungen", "terms of use"}
      ]

      for {path, fragment} <- cases do
        description = conn |> get(path) |> html_response(200) |> og("og:description")
        assert description =~ fragment, "expected #{path} description to mention #{fragment}"
        refute description =~ "business network"
      end
    end

    test "a tag page names the tag in its description", %{conn: conn} do
      insert(:tag, name: "Elixir", slug: "elixir")

      description = conn |> get(~p"/tags/elixir") |> html_response(200) |> og("og:description")

      # Not "members tagged Elixir": since issue #946 the page leads with the
      # posts carrying the tag, and most tag pages have no endorsed members at
      # all, so the old copy promised a search visitor a list that wasn't there.
      assert description == "Posts and members on vutuv about Elixir."
    end

    test "each settings page describes what it manages", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      cases = [
        {~p"/settings", "Manage your vutuv account"},
        {~p"/settings/security", "Manage how you sign in"},
        {~p"/settings/emails", "email addresses on your vutuv profile"},
        {~p"/settings/links", "links on your vutuv profile"},
        {~p"/settings/notifications", "which vutuv activity"}
      ]

      for {path, fragment} <- cases do
        description = conn |> get(path) |> html_response(200) |> og("og:description")
        assert description =~ fragment, "expected #{path} description to mention #{fragment}"
      end
    end
  end

  describe "profile pages" do
    test "a member previews with name, work info and avatar", %{conn: conn} do
      user =
        insert_activated_user(
          first_name: "Greta",
          last_name: "Tester",
          avatar: "selfie.jpg"
        )

      insert(:work_experience, user: user, title: "Developer", organization: "Acme Corp")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert og(html, "og:type") == "profile"
      # The title carries the member's current work line, not just the bare
      # name — the strongest on-page signal for name + role searches.
      assert og(html, "og:title") == "Greta Tester · Developer @ Acme Corp"
      assert title(html) == "Greta Tester · Developer @ Acme Corp - vutuv"
      assert og(html, "og:description") =~ "Acme Corp"
      assert og(html, "og:url") == @base <> "/#{user.username}"
      assert og(html, "og:image") == @base <> "/#{user.username}/avatar.jpg"
      assert og(html, "og:image:width") == "512"
      assert og(html, "og:image:type") == "image/jpeg"
      assert html =~ ~s(<meta name="twitter:card" content="summary")
      # The og:type=profile structured properties, so scrapers get the parts.
      assert og(html, "profile:first_name") == "Greta"
      assert og(html, "profile:last_name") == "Tester"
      assert og(html, "profile:username") == user.username
    end

    test "a member without work info titles with their headline instead", %{conn: conn} do
      user =
        insert_activated_user(
          first_name: "Head",
          last_name: "Liner",
          headline: "Coaching **great** teams"
        )

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert og(html, "og:title") == "Head Liner · Coaching great teams"
    end

    test "a member with neither work nor headline keeps the bare name title", %{conn: conn} do
      user = insert_activated_user(first_name: "Bare", last_name: "Name")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert og(html, "og:title") == "Bare Name"
      assert title(html) == "Bare Name - vutuv"
    end

    test "a member without an avatar falls back to the brand card", %{conn: conn} do
      user = insert_activated_user(first_name: "Bare")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert og(html, "og:image") == @base <> "/og-card.png"
    end

    test "a member without work info or tags gets the site description, never an empty one",
         %{conn: conn} do
      user = insert_activated_user(first_name: "Plain")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      description = og(html, "og:description")
      assert description != ""
      assert description =~ "business network"
    end

    test "a member's preview shows the follower count and never the tag list", %{conn: conn} do
      user = insert_activated_user(first_name: "Greta", last_name: "Tester")

      insert(:work_experience, user: user, title: "Developer", organization: "Acme Corp")
      insert(:user_tag, user: user, tag: insert(:tag, name: "Elixir"))

      for _ <- 1..3, do: follow!(insert_activated_user(), user)

      description = conn |> get(~p"/#{user}") |> html_response(200) |> og("og:description")

      assert description =~ "Acme Corp"
      assert description =~ "3 followers"
      # The tag list used to ride along in the preview ("... tags: Elixir");
      # it must not any more.
      refute description =~ "tags:"
      refute description =~ "Elixir"
    end

    test "a member with followers but no work info previews the follower count", %{conn: conn} do
      user = insert_activated_user(first_name: "Solo")
      follow!(insert_activated_user(), user)

      description = conn |> get(~p"/#{user}") |> html_response(200) |> og("og:description")

      assert description == "1 follower"
    end
  end

  describe "post pages" do
    test "a public post previews as an article with its first line", %{conn: conn} do
      author = insert_activated_user(first_name: "Paula", avatar: "selfie.jpg")
      post = create_post!(author, %{"body" => "Hello preview world, this is the first line."})

      html = conn |> get(Posts.path(post)) |> html_response(200)

      assert og(html, "og:type") == "article"
      assert og(html, "og:description") =~ "Hello preview world"
      assert og(html, "article:published_time") == Date.to_iso8601(post.published_on)
      # The author's avatar gives the preview a face.
      assert og(html, "og:image") == @base <> "/#{author.username}/avatar.jpg"
    end

    test "a post with images previews its first image instead of the avatar", %{conn: conn} do
      author = insert_activated_user(first_name: "Painter", avatar: "selfie.jpg")
      post = create_post!(author, %{"body" => "look at this"})

      # Position decides "first", not insertion order.
      insert(:post_image, post: post, user: author, position: 1, width: 800, height: 600)

      first =
        insert(:post_image,
          post: post,
          user: author,
          position: 0,
          width: 2000,
          height: 1000,
          alt: "A wide painting"
        )

      html = conn |> get(Posts.path(post)) |> html_response(200)

      assert og(html, "og:image") == @base <> "/post_images/#{first.token}/og.jpg"
      assert og(html, "og:image:width") == "1200"
      assert og(html, "og:image:height") == "600"
      assert og(html, "og:image:type") == "image/jpeg"
      assert og(html, "og:image:alt") == "A wide painting"
      assert html =~ ~s(<meta name="twitter:card" content="summary_large_image")
    end

    test "a restricted post's image stays out of the preview", %{conn: conn} do
      author = insert_activated_user(avatar: "selfie.jpg")

      post =
        create_post!(author, %{
          "body" => "members only",
          "denials" => [%{"wildcard" => "logged_out"}]
        })

      insert(:post_image, post: post, user: author, width: 800, height: 600)

      {member_conn, _member} = create_and_login_user(conn)
      html = member_conn |> get(Posts.path(post)) |> html_response(200)

      refute og(html, "og:image") =~ "/post_images/"
    end

    test "a restricted post never leaks its body into the preview", %{conn: conn} do
      author = insert_activated_user()

      post =
        create_post!(author, %{
          "body" => "secret words for members",
          "denials" => [%{"wildcard" => "logged_out"}]
        })

      # The permitted (logged-in) rendering still must not advertise the body:
      # scrapers fetch anonymously, but the tags shouldn't carry it anywhere.
      {member_conn, _member} = create_and_login_user(conn)
      html = member_conn |> get(Posts.path(post)) |> html_response(200)

      refute html =~ ~s(content="secret words)
      refute og(html, "og:description") =~ "secret words"
    end

    test "the teaser previews the author, not the post", %{conn: conn} do
      author = insert_activated_user(first_name: "Quiet")

      post =
        create_post!(author, %{
          "body" => "followers only content",
          "denials" => [%{"wildcard" => "non_followers"}]
        })

      html = conn |> get(Posts.path(post)) |> html_response(200)

      refute html =~ ~s(content="followers only)
      assert og(html, "og:type") == "profile"
    end
  end

  # Issue #1581: a shared organization link previewed with the *directory's*
  # copy and the brand card — the same card under every page, and under every
  # post they published, which told a reader in Teams or WhatsApp nothing about
  # what was behind the link. `async: false` for these is impossible inside an
  # async case, so the organization helpers' global flag is set per test.
  describe "organization pages" do
    setup :verify_organization_domains

    test "a page previews with its name, its own description and its logo", %{conn: conn} do
      {organization, _owner} = active_organization(%{"name" => "Acme GmbH"})

      {:ok, organization} =
        Organizations.update_organization(organization, %{
          "description" => "We build **great** widgets.\n\nSince 1994."
        })

      # `logo` is not castable from the edit form — `Organizations.store_logo/4`
      # owns that column — so set it the way the upload path does.
      organization = organization |> Ecto.Changeset.change(logo: "logo-token") |> Repo.update!()

      html = conn |> get(~p"/organizations/#{organization.slug}") |> html_response(200)

      assert og(html, "og:title") == "Acme GmbH"
      assert title(html) == "Acme GmbH - vutuv"
      # The page's own words, flattened out of their Markdown — not the
      # directory's "Verified organization pages on vutuv…".
      assert og(html, "og:description") == "We build great widgets. Since 1994."
      refute og(html, "og:description") =~ "Verified organization pages"
      # An account page, like a member's, not a generic website.
      assert og(html, "og:type") == "profile"

      assert og(html, "og:image") ==
               @base <> "/organizations/#{organization.slug}/avatar.jpg"

      assert og(html, "og:image:width") == "512"
      assert og(html, "og:image:type") == "image/jpeg"
      assert og(html, "og:image:alt") == "Acme GmbH"
      assert html =~ ~s(<meta name="twitter:card" content="summary")
    end

    test "a page with a root handle names it, one without carries no profile tag",
         %{conn: conn} do
      {organization, _owner} = active_organization()
      {:ok, handled} = Organizations.claim_handle(organization, %{"username" => "acmehandle"})

      html = conn |> get(~p"/organizations/#{handled.slug}") |> html_response(200)
      assert og(html, "profile:username") == "acmehandle"

      {plain, _owner} = active_organization(%{"website_url" => "https://plain.example"})
      html = conn |> get(~p"/organizations/#{plain.slug}") |> html_response(200)
      assert og(html, "profile:username") == nil
      # A page invents no name for itself either.
      assert og(html, "profile:first_name") == nil
    end

    test "a page without a logo falls back to the brand card", %{conn: conn} do
      {organization, _owner} = active_organization()

      html = conn |> get(~p"/organizations/#{organization.slug}") |> html_response(200)

      assert og(html, "og:image") == @base <> "/og-card.png"
    end

    test "a page that has written no description gets the site pitch, not the directory copy",
         %{conn: conn} do
      {organization, _owner} = active_organization()

      description =
        conn
        |> get(~p"/organizations/#{organization.slug}")
        |> html_response(200)
        |> og("og:description")

      assert description =~ "business network"
      refute description =~ "Verified organization pages"
    end

    test "the directory itself keeps its own copy", %{conn: conn} do
      description = conn |> get(~p"/organizations") |> html_response(200) |> og("og:description")

      assert description =~ "Verified organization pages"
    end

    # The bug the feature uncovered, pinned on its own: `page_copy/1` matched
    # `["organizations" | _]`, so the directory's one sentence described every
    # page below the prefix and every post they published.
    #
    # Asserted against `description/1` rather than against the three routes that
    # exist today, because the failure mode is the *next* route somebody adds
    # under `/organizations/` — a jobs tab, a members list — silently inheriting
    # the copy again. A path is all the chain needs (`path_description/1` reads
    # `conn.request_path`), so an unrouted path stands in for that future page.
    test "only the bare directory path carries the directory copy", %{conn: conn} do
      directory = "Verified organization pages on vutuv, each with a proven web domain."

      describe_path = fn path ->
        OpenGraph.description(%{conn: %{conn | request_path: path}})
      end

      assert describe_path.("/organizations") == directory

      for path <- [
            "/organizations/acme",
            "/organizations/acme/posts/01a04298-dd43-7897-a2fc-5ed7c44028c6",
            "/organizations/acme/following",
            # The route nobody has written yet — the case this test exists for.
            "/organizations/acme/jobs"
          ] do
        refute describe_path.(path) == directory,
               "#{path} inherited the directory copy"
      end

      # The wizard sits under the prefix too and says what it is, rather than
      # falling through to the site pitch with everything else.
      assert describe_path.("/organizations/new") ==
               "Claim a page for your organization on vutuv."
    end

    # The claim wizard sits under /organizations too and used to borrow the
    # directory's copy; asserted in German as well, because that is what a
    # vutuv reader actually gets and an unwritten (or fuzzy-filled) .po entry
    # passes every English check.
    test "the claim wizard describes itself, in the reader's own language", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      description =
        conn |> get(~p"/organizations/new") |> html_response(200) |> og("og:description")

      assert description == "Claim a page for your organization on vutuv."

      user |> Ecto.Changeset.change(locale: "de") |> Vutuv.Repo.update!()

      german = conn |> get(~p"/organizations/new") |> html_response(200) |> og("og:description")

      assert german == "Reservieren Sie eine Seite für Ihre Organisation auf vutuv."
    end
  end

  describe "organization post pages" do
    setup :verify_organization_domains

    test "a page's post previews like a member's: teaser, date and the page's logo",
         %{conn: conn} do
      {organization, owner} = active_organization(%{"name" => "Acme GmbH"})
      # `logo` is not castable from the edit form; the upload path owns it.
      organization = organization |> Ecto.Changeset.change(logo: "tok") |> Repo.update!()
      {:ok, _role} = Organizations.add_role(organization, owner, "publisher", owner)

      {:ok, post} =
        Posts.create_organization_post(organization, owner, %{
          body: "We are hiring three developers."
        })

      html = conn |> get(Posts.path(post)) |> html_response(200)

      assert og(html, "og:type") == "article"
      assert og(html, "og:description") =~ "hiring three developers"
      refute og(html, "og:description") =~ "Verified organization pages"
      assert og(html, "article:published_time") == Date.to_iso8601(post.published_on)
      # The title distinguishes the post from the page it was published on.
      assert og(html, "og:title") == "Acme GmbH · #{Date.to_iso8601(post.published_on)}"
      # No picture of its own, so the page behind it gives the card a face.
      assert og(html, "og:image") ==
               @base <> "/organizations/#{organization.slug}/avatar.jpg"

      assert og(html, "og:image:alt") == "Acme GmbH"
    end

    test "an attached image beats the page logo", %{conn: conn} do
      {organization, owner} = active_organization()
      {:ok, organization} = Organizations.update_organization(organization, %{"logo" => "tok"})
      {:ok, _role} = Organizations.add_role(organization, owner, "publisher", owner)
      {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "look"})

      image =
        insert(:post_image,
          post: post,
          user: owner,
          position: 0,
          width: 2000,
          height: 1000,
          alt: "Our new office"
        )

      html = conn |> get(Posts.path(post)) |> html_response(200)

      assert og(html, "og:image") == @base <> "/post_images/#{image.token}/og.jpg"
      assert og(html, "og:image:alt") == "Our new office"
      assert html =~ ~s(<meta name="twitter:card" content="summary_large_image")
    end
  end

  # The organization helpers claim a page by proving a domain, which reads the
  # global `:verify_organization_domains` flag — hence one setup shared by both
  # organization describes rather than a copy in each.
  defp verify_organization_domains(_context) do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  describe "GET /og-card.png" do
    test "serves the generated brand card, cacheable", %{conn: conn} do
      conn = get(conn, "/og-card.png")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert [cache] = get_resp_header(conn, "cache-control")
      assert cache =~ "public"
      assert <<137, ?P, ?N, ?G, _rest::binary>> = conn.resp_body
    end
  end
end
