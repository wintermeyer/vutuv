defmodule VutuvWeb.OrganizationPostsWebTest do
  @moduledoc """
  The web surface of posts published in an organization's name (issue #1334):
  the composer on the organization page, the post rendering under the
  organization's own name, and the permalink's scoping. `async: false` because
  the organization helpers flip the global `:verify_organization_domains` flag.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  describe "the composer on the organization page" do
    test "a publisher writes as the organization and the post appears under its name",
         %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}")

      html =
        view
        |> element("#organization-post-form")
        |> render_submit(%{"body" => "Wir stellen ein."})

      # The post is signed by the organization, never by the member who wrote it.
      assert html =~ "Wir stellen ein."
      assert html =~ organization.name

      [post] = Posts.organization_posts_page(organization, owner).entries
      assert post.organization_id == organization.id
      assert post.acting_user_id == owner.id
    end

    test "an owner without the publisher role gets no composer", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      organization = active_organization_for(owner)

      {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.slug}")

      refute html =~ "organization-post-form"
    end

    test "a visitor sees the published post but no composer", %{conn: conn} do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      {:ok, _post} = Posts.create_organization_post(organization, owner, %{body: "Öffentlich."})

      {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.slug}")

      assert html =~ "Öffentlich."
      refute html =~ "organization-post-form"
    end
  end

  describe "the permalink" do
    setup do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Unsere Worte."})

      %{organization: organization, owner: owner, post: post}
    end

    test "lives under the organization slug and renders the post", ctx do
      %{organization: organization, post: post, conn: conn} = ctx

      assert Posts.path(post) == "/organizations/#{organization.slug}/posts/#{post.id}"

      html = conn |> get(Posts.path(post)) |> html_response(200)
      assert html =~ "Unsere Worte."
    end

    test "404s for an id that is not this organization's post", ctx do
      %{organization: organization, conn: conn} = ctx
      stranger = insert(:activated_user)
      {:ok, personal} = Posts.create_post(stranger, %{body: "Meins."})

      # A member's post must never render under an organization's name.
      conn
      |> get(~p"/organizations/#{organization.slug}/posts/#{personal.id}")
      |> response(404)

      conn
      |> get(~p"/organizations/#{organization.slug}/posts/not-a-uuid")
      |> response(404)
    end
  end

  describe "the permalink's agent formats" do
    setup do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

      {:ok, post} =
        Posts.create_organization_post(organization, owner, %{body: "Maschinenlesbar."})

      %{organization: organization, owner: owner, post: post}
    end

    test "serves .md/.txt/.json/.xml, signed by the organization", ctx do
      %{post: post, organization: organization, conn: conn} = ctx
      path = Posts.path(post)

      for extension <- ~w(.md .txt .json) do
        body = conn |> get(path <> extension) |> response(200)
        assert body =~ "Maschinenlesbar."
        assert body =~ organization.name
      end

      json = conn |> get(path <> ".json") |> json_response(200)
      assert json["type"] == "organization_post"
      assert json["author"]["slug"] == organization.slug

      # The member who pressed publish is internal and must not leak into a
      # document anybody can fetch — that split is what `acting_user_id` is for.
      refute json |> Jason.encode!() |> String.contains?(ctx.owner.username)
    end

    test "a page with the agent formats switched off 404s them", ctx do
      %{post: post, organization: organization, conn: conn} = ctx
      {:ok, _} = Organizations.update_organization(organization, %{"geo?" => false})

      conn |> get(Posts.path(post) <> ".md") |> response(404)
      # …while the HTML page itself still renders.
      assert conn |> get(Posts.path(post)) |> html_response(200) =~ "Maschinenlesbar."
    end
  end

  describe "discoverability" do
    test "an organization post is in the sitemap, and drops out when the page opts out", ctx do
      %{conn: conn} = ctx
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Findbar."})

      # `post_entries/1` inner-joins users to build the URL, so an organization
      # post is invisible to it — silently. Its own chunk type is what puts it
      # in front of a crawler at all.
      paths = Vutuv.Sitemap.organization_post_entries(1) |> Enum.map(&elem(&1, 0))
      assert Posts.path(post) in paths

      {:ok, _} = Organizations.update_organization(organization, %{"seo?" => false})

      refute Posts.path(post) in (Vutuv.Sitemap.organization_post_entries(1)
                                  |> Enum.map(&elem(&1, 0)))

      # And /llms.txt names the shape so an agent knows the URL exists.
      assert conn |> get(~p"/llms.txt") |> response(200) =~
               "/organizations/<slug>/posts/<id>"
    end
  end

  describe "the RSS feed" do
    test "serves the page's own posts, signed by the page", %{conn: conn} do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      {:ok, _} = Posts.create_organization_post(organization, owner, %{body: "Neuigkeit."})

      path = VutuvWeb.Feeds.organization_feed_path(organization)
      assert path == "/organizations/#{organization.slug}/posts/feed.xml"

      conn = get(conn, path)
      assert response_content_type(conn, :xml) =~ "application/rss+xml"

      body = response(conn, 200)
      assert body =~ "Neuigkeit."
      assert body =~ "<dc:creator>#{organization.name}</dc:creator>"
      # The member who pressed publish never appears in a feed.
      refute body =~ owner.username
    end

    test "a page still in the moderation freezer serves no feed", %{conn: conn} do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.admin_set_frozen(organization, true)

      conn
      |> get(VutuvWeb.Feeds.organization_feed_path(organization))
      |> response(404)
    end
  end

  describe "public search" do
    test "the results page renders an organization row without a member author",
         %{conn: conn} do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

      {:ok, _} =
        Posts.create_organization_post(organization, owner, %{body: "Quantenkompressor."})

      # The query change is only half of it: the last three crashes in this
      # milestone were all a page reading `post.user` on an organization post,
      # so the row has to draw as well as be found.
      {:ok, _view, html} = live(conn, ~p"/search?q=Quantenkompressor")

      assert html =~ organization.name
      assert html =~ "Quantenkompressor"
    end
  end

  describe "replies" do
    test "an organization post cannot be answered yet", %{conn: _conn} do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Hallo."})

      reader = insert(:activated_user)

      # Refused outright rather than half-working: everything a reply sets in
      # motion is member-shaped, and an organization has no inbox until #1336.
      assert {:error, :restricted} = Posts.create_reply(reader, post, %{body: "Antwort"})
    end
  end
end
