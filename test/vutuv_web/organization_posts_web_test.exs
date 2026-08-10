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
