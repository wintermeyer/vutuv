defmodule VutuvWeb.SettingsOrganizationsTest do
  @moduledoc """
  The member's "Your organizations" hub at `/settings/organizations`: the
  login-required page that lists the organization pages a member owns or helps
  run (including ones still finishing domain verification), spells out in plain
  language what an organization page is and how ownership works (creator becomes
  owner, can invite others, can transfer ownership, can add a handle), and
  carries the "Add your organization" call to action. The public browse
  directory stays at `/organizations`.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Organizations.OrganizationRole
  alias Vutuv.Repo

  # Insert a bare role row without the domain-verification dance, so these tests
  # stay `async: true` (no global `:verify_organization_domains` flag flip).
  defp put_role(organization, user, role) do
    Repo.insert!(
      OrganizationRole.changeset(%OrganizationRole{}, %{
        organization_id: organization.id,
        user_id: user.id,
        role: role,
        granted_by_user_id: user.id
      })
    )
  end

  test "logged out, the page requires a login", %{conn: conn} do
    assert conn |> get(~p"/settings/organizations") |> redirected_to() == "/"
  end

  describe "the member's organizations" do
    test "lists the ones the member owns or helps run, including pending pages", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      owned = insert(:organization, name: "Acme Owned GmbH")
      put_role(owned, user, "owner")

      # A page still finishing domain verification must show, so the member can
      # come back and finish the claim.
      pending = insert(:organization, name: "Pending Verein", status: "pending")
      put_role(pending, user, "owner")

      # A page the member was invited onto (not the creator) also belongs here.
      helped = insert(:organization, name: "Helped NGO")
      put_role(helped, user, "admin")

      # A page the member has no role on must never appear.
      _stranger = insert(:organization, name: "Stranger Behörde")

      html = conn |> get(~p"/settings/organizations") |> html_response(200)

      assert html =~ ~s(id="your-organizations")
      assert html =~ "Acme Owned GmbH"
      assert html =~ "Pending Verein"
      assert html =~ "Helped NGO"
      refute html =~ "Stranger Behörde"

      # Each row links to that organization's page.
      assert html =~ ~s(href="#{~p"/organizations/#{owned.slug}"}")
    end

    test "shows the explainer and the add-your-organization call to action", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/organizations") |> html_response(200)

      # The plain-language explainer of what an organization is + how it works.
      assert html =~ ~s(id="organizations-explainer")
      # The add call to action opens the claim wizard.
      assert html =~ ~s(href="#{~p"/organizations/new"}")
    end

    test "a member with no organizations still sees the explainer and the add CTA", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/organizations") |> html_response(200)

      assert html =~ ~s(id="organizations-explainer")
      assert html =~ ~s(href="#{~p"/organizations/new"}")
      # No "Your organizations" list when the member has none.
      refute html =~ ~s(id="your-organizations")
    end
  end
end
