defmodule VutuvWeb.OrganizationManageTabsTest do
  @moduledoc """
  The tab bar every organization management page shares (issue #1484).

  All nine pages render `VutuvWeb.OrganizationComponents.manage_header/1`, so the
  tab set has to follow the viewer's roles alone — never which page they happen
  to be standing on. It did not: `publisher?` was an optional attribute
  defaulting to `false`, and the four pages that forgot to pass it dropped the
  Feed and Follows tabs, so the page's own reading list was reachable from two
  pages out of six. `async: false` because the organization helpers flip the
  global `:verify_organization_domains` flag.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Organizations

  import Vutuv.OrganizationsHelpers

  # Every management page an owner reaches without holding `publisher`.
  @owner_pages ~w(edit roles domains exclusions activity fediverse)
  # … and the two the role itself unlocks.
  @publisher_pages ~w(feed following)

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  test "a publisher reaches the Feed and Follows tabs from every management page",
       %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

    for page <- @owner_pages ++ @publisher_pages do
      html = manage_page(conn, organization, page)

      assert html =~ tab_href(organization, "feed"),
             "the Feed tab is missing on /organizations/:slug/#{page}"

      assert html =~ tab_href(organization, "following"),
             "the Follows tab is missing on /organizations/:slug/#{page}"
    end
  end

  test "an owner who is not a publisher gets neither tab on any page", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)

    for page <- @owner_pages do
      html = manage_page(conn, organization, page)

      refute html =~ tab_href(organization, "feed"),
             "/organizations/:slug/#{page} offers a Feed tab the viewer may not open"

      refute html =~ tab_href(organization, "following"),
             "/organizations/:slug/#{page} offers a Follows tab the viewer may not open"
    end
  end

  defp manage_page(conn, organization, page) do
    conn
    |> get("/organizations/#{organization.slug}/#{page}")
    |> html_response(200)
  end

  defp tab_href(organization, page), do: ~s|href="/organizations/#{organization.slug}/#{page}"|
end
