defmodule VutuvWeb.OrganizationFediverseFollowersWebTest do
  @moduledoc """
  Who follows a page from other networks
  (`/organizations/:slug/fediverse/followers`).

  The Fediverse card knew the number and not one name, so a team could see the
  reach it had switched on and never who it reached. `list_organization_followers/2`
  had been there since #1334 with no page reading it.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Organizations
  alias Vutuv.Repo

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp federating_page(conn) do
    {conn, owner} = create_and_login_user(conn)

    page =
      active_organization_for(owner)
      |> Ecto.Changeset.change(%{username: "acme", fediverse_followers?: true})
      |> Repo.update!()

    {:ok, _} = Fediverse.ensure_organization_actor(page)

    {conn, page, owner}
  end

  defp follower!(page, overrides) do
    {:ok, follower} =
      Fediverse.add_organization_follower(
        page,
        Map.merge(
          %{
            actor_uri: "https://remote.example/users/frida",
            inbox_uri: "https://remote.example/users/frida/inbox",
            handle: "@frida@remote.example",
            name: "Frida Fern"
          },
          overrides
        )
      )

    follower
  end

  test "the owner reads who follows the page, and where from", %{conn: conn} do
    {conn, page, _owner} = federating_page(conn)
    follower!(page, %{})

    {:ok, _view, html} = live(conn, ~p"/organizations/#{page.slug}/fediverse/followers")

    assert html =~ "Frida Fern"
    assert html =~ "@frida@remote.example"
    assert html =~ "remote.example"
    # The link out goes to the account on its own server, never to a vutuv page.
    assert html =~ ~s(href="https://remote.example/users/frida")
  end

  test "the Fediverse card offers the way in once somebody follows", %{conn: conn} do
    {conn, page, _owner} = federating_page(conn)

    # Nobody yet: an empty list is never offered as a destination.
    {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}/fediverse")
    refute has_element?(view, "#all-followers-link")

    follower!(page, %{})

    {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}/fediverse")
    assert has_element?(view, "#all-followers-link")
  end

  test "searching and the server filter narrow the list", %{conn: conn} do
    {conn, page, _owner} = federating_page(conn)
    follower!(page, %{})

    follower!(page, %{
      actor_uri: "https://andere.example/users/hans",
      inbox_uri: "https://andere.example/users/hans/inbox",
      handle: "@hans@andere.example",
      name: "Hans Hummel"
    })

    {:ok, view, html} = live(conn, ~p"/organizations/#{page.slug}/fediverse/followers")
    assert html =~ "Frida Fern"
    assert html =~ "Hans Hummel"

    html = render_change(element(view, "#follower-filter"), %{"q" => "hans", "server" => ""})
    assert html =~ "Hans Hummel"
    refute html =~ "Frida Fern"

    # The view lives in the socket, not in the URL: this page is embedded by the
    # controller through `live_render`, so it is not mounted at the router and
    # cannot patch. Clearing has to put the whole list back.
    html = render_click(element(view, "#clear-filters"))
    assert html =~ "Frida Fern"

    html = render_click(view, "filter_server", %{"host" => "andere.example"})
    assert html =~ "Hans Hummel"
    refute html =~ "Frida Fern"
  end

  test "a page's list never shows a member's followers", %{conn: conn} do
    {conn, page, _owner} = federating_page(conn)
    member = insert(:activated_user)

    {:ok, _} =
      Fediverse.add_follower(member, %{
        actor_uri: "https://remote.example/users/mine",
        inbox_uri: "https://remote.example/users/mine/inbox",
        handle: "@mine@remote.example",
        name: "Nur Meiner"
      })

    {:ok, _view, html} = live(conn, ~p"/organizations/#{page.slug}/fediverse/followers")

    refute html =~ "Nur Meiner"
    assert html =~ "Nobody yet"
  end

  test "a role holder who is not the owner gets a 404", %{conn: conn} do
    # Logged in FIRST on purpose: `sent_pin/0` reads the oldest mail in this
    # process's mailbox, and creating a page mails its owner, so a login after
    # that would read a page notice and find no PIN in it.
    {other_conn, other} =
      build_conn() |> Plug.Test.init_test_session(%{}) |> create_and_login_user()

    {_conn, page, _owner} = federating_page(conn)
    follower!(page, %{})

    {:ok, _} = Organizations.add_role(page, other, "publisher", other)

    assert other_conn
           |> get(~p"/organizations/#{page.slug}/fediverse/followers")
           |> response(404)
  end
end
