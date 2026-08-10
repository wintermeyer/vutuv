defmodule VutuvWeb.OrganizationFollowWebTest do
  @moduledoc """
  The follow control on an organization page (issue #1336). `async: false`
  because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Social

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  test "a member follows and unfollows with no reload, and the count follows", %{conn: conn} do
    {conn, member} = create_and_login_user(conn)
    owner = insert(:activated_user)
    organization = active_organization_for(owner)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}")

    view |> element("#organization-follow") |> render_click()
    assert Social.follows_organization?(member, organization)
    assert render(view) =~ "data-organization-followers"

    view |> element("#organization-follow") |> render_click()
    refute Social.follows_organization?(member, organization)
  end

  test "a logged-out visitor gets no follow control", %{conn: conn} do
    owner = insert(:activated_user)
    organization = active_organization_for(owner)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}")

    refute has_element?(view, "#organization-follow")
  end

  test "an organization's posts reach a follower's feed page", %{conn: conn} do
    {conn, member} = create_and_login_user(conn)
    owner = insert(:activated_user)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {:ok, _} = Vutuv.Posts.create_organization_post(organization, owner, %{body: "Frisch."})
    {:ok, _} = Social.follow_organization(member, organization)

    {:ok, _view, html} = live(conn, ~p"/feed")

    assert html =~ "Frisch."
    # Signed by the page, not by the member who wrote it.
    assert html =~ organization.name
  end
end
