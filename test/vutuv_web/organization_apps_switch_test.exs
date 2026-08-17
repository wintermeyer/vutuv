defmodule VutuvWeb.OrganizationAppsSwitchTest do
  @moduledoc """
  The owner's switch for reaching a page from a Mastodon-compatible app
  (`/organizations/:slug/apps`), the page twin of a member's `/settings/apps`.

  Its own tab rather than a card on the Fediverse page: publishing to servers we
  do not run and letting the Editorial team use a phone app are two decisions,
  and one card made them read as one. Owner-only all the same — this is an
  administrative question about the page, not part of speaking for it.

  Off by default, which is the whole reason the page has to name the address a
  member types; a switch nobody can find an address for is not a feature.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Organizations.OrganizationRole
  alias Vutuv.Repo

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp owned_page(conn) do
    {conn, owner} = create_and_login_user(conn)
    {conn, active_organization_for(owner), owner}
  end

  test "app access is off until the owner turns it on", %{conn: conn} do
    {conn, page, _owner} = owned_page(conn)
    refute page.mastodon_clients?

    {:ok, view, html} = live(conn, ~p"/organizations/#{page.slug}/apps")
    assert html =~ "mastodon-client-access"
    # Nothing to type anywhere until the switch is on, so the address is not
    # offered yet.
    refute html =~ "mastodon-address"

    html = render_click(view, "toggle", %{})

    assert Organizations.get_organization!(page.id).mastodon_clients?
    assert html =~ "mastodon-address"
    assert html =~ VutuvWeb.Endpoint.host()
    assert html =~ ~p"/system/mastodon"
  end

  test "and the owner can turn it back off", %{conn: conn} do
    {conn, page, _owner} = owned_page(conn)
    {:ok, page} = Organizations.set_mastodon_clients(page, true)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}/apps")
    render_click(view, "toggle", %{})

    refute Organizations.get_organization!(page.id).mastodon_clients?
  end

  # The page is gated before it mounts, but a socket outlives the grant that
  # opened it, so the write re-asks. Calibrated against the un-fixed handler:
  # without the `owner?/2` check the switch really does flip here.
  test "an open page stops switching after the ownership is withdrawn", %{conn: conn} do
    {conn, page, owner} = owned_page(conn)
    {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}/apps")

    Repo.delete!(Repo.get_by!(OrganizationRole, organization_id: page.id, role: "owner"))
    render_click(view, "toggle", %{})

    refute Organizations.get_organization!(page.id).mastodon_clients?
  end

  test "a publisher who is not the owner cannot reach it", %{conn: conn} do
    {conn, member} = create_and_login_user(conn)
    owner = insert(:activated_user)
    page = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(page, member, "publisher", owner)

    assert conn |> get(~p"/organizations/#{page.slug}/apps") |> response(404)
  end

  test "the owner sees the Apps tab", %{conn: conn} do
    {conn, page, _owner} = owned_page(conn)

    assert conn |> get(~p"/organizations/#{page.slug}/activity") |> html_response(200) =~
             "#{page.slug}/apps"
  end

  test "a publisher does not see it", %{conn: conn} do
    {conn, publisher} = create_and_login_user(conn)
    owner = insert(:activated_user)
    page = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(page, publisher, "publisher", owner)

    refute conn |> get(~p"/organizations/#{page.slug}/activity") |> html_response(200) =~
             "#{page.slug}/apps"
  end

  test "the page reads as German", %{conn: conn} do
    {conn, page, _owner} = owned_page(conn)

    html =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de")
      |> get(~p"/organizations/#{page.slug}/apps")
      |> html_response(200)

    assert html =~ "Mastodon-kompatible Apps"
    assert html =~ "App-Zugriff einschalten"
  end
end
