defmodule VutuvWeb.OrganizationManagementTest do
  @moduledoc """
  The organization management web surface (issue #930): the owner-only roles and
  domains pages, alias editing on the edit page, the /organizations agent formats
  carrying aliases, and the /admin/organizations oversight dashboard. `async: false`
  because domain verification flips the global `:verify_organization_domains` flag and
  injects a DNS resolver.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations

  @valid Vutuv.OrganizationsHelpers.valid_organization_attrs()

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  # An active organization owned by `owner` (an already-persisted %User{}).
  describe "roles page" do
    test "owner adds a member; the new admin can edit but not manage roles", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      organization = active_organization_for(owner)
      member = insert(:activated_user)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/roles")

      view
      |> element("#add-member-form")
      |> render_submit(%{"identifier" => "@" <> member.username, "role" => "admin"})

      assert render(view) =~ member.username
      assert Organizations.role_of(organization, member) == "admin"
    end

    test "the last owner cannot leave", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      organization = active_organization_for(owner)

      role =
        Organizations.role_of(organization, owner) && hd(Organizations.list_roles(organization))

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/roles")
      html = view |> element("#role-#{role.id} button", "Leave") |> render_click()

      assert html =~ "at least one owner"
      assert Organizations.role_of(organization, owner) == "owner"
    end

    test "a logged-in non-member cannot open the roles page", %{conn: conn} do
      # Log in first, so the only PIN in the mailbox is this login's (the organization
      # claim below sends the operator's verified-notice email).
      {stranger_conn, _stranger} = create_and_login_user(conn)
      owner = insert(:activated_user)
      organization = active_organization_for(owner)

      assert stranger_conn |> get(~p"/organizations/#{organization.slug}/roles") |> response(404)

      assert stranger_conn
             |> get(~p"/organizations/#{organization.slug}/domains")
             |> response(404)
    end
  end

  describe "domains page" do
    test "owner adds and verifies a second domain, then makes it primary", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      organization = active_organization_for(owner)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/domains")

      view
      |> element("#add-domain-form")
      |> render_submit(%{"domain" => "acme.de", "method" => "dns"})

      second = Enum.find(Organizations.list_domains(organization), &(&1.domain == "acme.de"))
      assert second

      # The inline verification panel shows the REAL TXT record, not the literal
      # `{@dns_value}` (a phx-no-curly-interpolation interpolation trap).
      html = render(view)
      assert html =~ "vutuv-organization-verify=#{second.verification_token}"
      refute html =~ "@dns_value"

      stub_dns(second.verification_token)

      view |> element("#verify-#{second.id}") |> render_click()
      assert Organizations.get_domain(organization, second.id).verified_at

      # The re-rendered page now offers "Make primary" for the verified domain.
      render(view)
      view |> element("#domain-#{second.id} button", "Make primary") |> render_click()
      assert Organizations.primary_domain(organization).domain == "acme.de"
    end

    test "removing the last verified domain is refused", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      organization = active_organization_for(owner)
      primary = Organizations.primary_domain(organization)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/domains")
      html = view |> element("#domain-#{primary.id} button", "Remove") |> render_click()

      assert html =~ "at least one verified domain"
      assert Organizations.primary_domain(organization).id == primary.id
    end
  end

  describe "pending page verification panel (#929 regression)" do
    test "the owner's verify panel shows the real DNS token, not a literal assign", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)

      {:ok, %{organization: organization, domain: domain}} =
        Organizations.create_pending_organization(owner, @valid, "dns")

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}")
      html = render(view)

      assert html =~ "vutuv-organization-verify=#{domain.verification_token}"
      refute html =~ "@dns_value"
    end
  end

  describe "aliases on the edit page" do
    test "owner adds an alias and the page + agent formats list it", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      organization = active_organization_for(owner)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/edit")

      view
      |> element("#add-alias-form")
      |> render_submit(%{"name" => "AcmeCorp", "kind" => "brand"})

      assert render(view) =~ "AcmeCorp"
      assert Enum.any?(Organizations.list_aliases(organization), &(&1.name == "AcmeCorp"))

      # The public page and its agent formats now show the alias.
      assert build_conn() |> get(~p"/organizations/#{organization.slug}") |> html_response(200) =~
               "AcmeCorp"

      assert build_conn() |> get("/organizations/#{organization.slug}.md") |> response(200) =~
               "AcmeCorp"

      json =
        build_conn()
        |> get("/organizations/#{organization.slug}.json")
        |> response(200)
        |> Jason.decode!()

      assert Enum.any?(json["aliases"], &(&1["name"] == "AcmeCorp"))
    end
  end

  describe "root handle on the edit page (issue #941)" do
    test "owner claims a handle and the organization gets a root URL", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      organization = active_organization_for(owner)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/edit")

      view
      |> element("#claim-handle-form")
      |> render_submit(%{"username" => "acmehandle"})

      assert Organizations.get_organization(organization.id).username == "acmehandle"

      # The organization page is now reachable at the root, canonical there, with
      # /organizations/:slug pointing at it.
      root = build_conn() |> get("/acmehandle") |> html_response(200)
      assert root =~ organization.name

      slug_page =
        build_conn() |> get(~p"/organizations/#{organization.slug}") |> html_response(200)

      assert slug_page =~ ~s(rel="canonical")
      assert slug_page =~ "/acmehandle"
    end

    test "an organization admin (not an owner) sees no claim form and a forged event is refused",
         %{conn: conn} do
      {conn, admin} = create_and_login_user(conn)
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, admin, "admin", owner)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/edit")

      # The claim form is owner-gated in the template.
      refute has_element?(view, "#claim-handle-form")

      # A forged socket event must not set the global root handle: an admin is
      # not an owner, and the handle lives in the shared /:handle namespace.
      render_click(view, "claim_handle", %{"username" => "adminhandle"})

      assert is_nil(Organizations.get_organization(organization.id).username)
      # The handle was never registered, so it stays claimable.
      assert Vutuv.Handles.available?("adminhandle")
    end

    test "owner cannot claim a handle already held by a member", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      organization = active_organization_for(owner)
      member = insert(:activated_user, username: "takenhandle")
      {:ok, _} = Vutuv.Handles.put_user_handle(member)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/edit")

      html =
        view
        |> element("#claim-handle-form")
        |> render_submit(%{"username" => "takenhandle"})

      assert html =~ "has already been taken"
      assert is_nil(Organizations.get_organization(organization.id).username)
    end
  end

  describe "danger zone: owner deletes the organization (issue #941)" do
    test "an owner permanently deletes the page; domain + handle are freed", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.claim_handle(organization, %{"username" => "acmegone"})

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/edit")

      view |> element("#delete-organization") |> render_click()

      assert_redirect(view, ~p"/organizations")
      assert is_nil(Organizations.get_organization(organization.id))
      assert build_conn() |> get(~p"/organizations/#{organization.slug}") |> response(404)
      # The freed handle and verified domain can be claimed again.
      assert Vutuv.Handles.available?("acmegone")

      assert is_nil(
               Vutuv.Repo.get_by(Vutuv.Organizations.OrganizationDomain, domain: "acme.example")
             )
    end

    test "an organization admin (not an owner) sees no delete control and is refused", %{
      conn: conn
    } do
      {conn, admin} = create_and_login_user(conn)
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, admin, "admin", owner)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/edit")

      refute has_element?(view, "#delete-organization")
      # Even a forged event is refused: the page still exists.
      render_click(view, "delete_organization", %{})
      assert Organizations.get_organization(organization.id)
    end
  end

  describe "admin dashboard" do
    test "an admin freezes and unfreezes an organization", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      owner = insert(:activated_user)
      organization = active_organization_for(owner)

      {:ok, view, _html} = live(conn, ~p"/admin/organizations")
      assert render(view) =~ organization.name

      view |> element("#organization-row-#{organization.id} button", "Details") |> render_click()
      view |> element("#organization-detail button", "Freeze") |> render_click()

      assert Organizations.get_organization(organization.id).frozen_at
      # A frozen page 404s for the public.
      assert build_conn() |> get(~p"/organizations/#{organization.slug}") |> response(404)

      view |> element("#organization-detail button", "Unfreeze") |> render_click()
      refute Organizations.get_organization(organization.id).frozen_at
      assert build_conn() |> get(~p"/organizations/#{organization.slug}") |> html_response(200)
    end

    test "an admin clears a ⚑ collision-flagged alias from the drawer", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      owner = insert(:activated_user)
      organization = active_organization_for(owner)

      _rival =
        active_organization_for(insert(:activated_user), %{
          "name" => "Globex SE",
          "website_url" => "https://globex.example"
        })

      # An alias equal to another verified organization's name lands flagged.
      {:ok, flagged} = Organizations.add_alias(organization, "Globex SE", "brand")
      assert flagged.flagged_at

      {:ok, view, _html} = live(conn, ~p"/admin/organizations")
      view |> element("#organization-row-#{organization.id} button", "Details") |> render_click()
      view |> element("#organization-detail button", "Clear") |> render_click()

      assert Organizations.get_alias(flagged.id).flagged_at == nil
      assert Organizations.flagged_aliases_count() == 0
    end

    test "a non-admin cannot reach the dashboard", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert conn |> get(~p"/admin/organizations") |> response(403)
    end
  end
end
