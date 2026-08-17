defmodule VutuvWeb.OrganizationFediverseSwitchTest do
  @moduledoc """
  The owner's federation switch (issue #1334) — the last piece, and the one that
  makes the rest reachable at all. Until it exists the whole half is code nobody
  can turn on.

  Owner-only, unlike the feed and the follows list beside it: it decides how the
  page appears on servers we do not run, and it cannot be fully taken back.

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

  defp owned_page(conn, handle \\ "acme") do
    {conn, owner} = create_and_login_user(conn)

    page =
      active_organization_for(owner)
      |> Ecto.Changeset.change(%{username: handle})
      |> Repo.update!()

    {conn, page, owner}
  end

  test "the owner switches federating on, and the keypair is there at once", %{conn: conn} do
    {conn, page, _owner} = owned_page(conn)

    refute Fediverse.federated?(page)

    {:ok, view, html} = live(conn, ~p"/organizations/#{page.slug}/fediverse")
    assert html =~ "@acme@#{VutuvWeb.Endpoint.host()}"

    render_click(view, "toggle", %{})

    page = Organizations.get_organization!(page.id)
    assert Fediverse.federated?(page)

    # Minted on the way in, not lazily on the first request: a remote server
    # resolving the handle a second later must find a complete actor.
    assert Fediverse.get_organization_actor(page)
  end

  test "switching off stops federating but keeps the keypair", %{conn: conn} do
    {conn, page, _owner} = owned_page(conn)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}/fediverse")
    render_click(view, "toggle", %{})
    render_click(view, "toggle", %{})

    page = Organizations.get_organization!(page.id)

    # `ever_federated?` keys on the keypair, not the switch, because turning it
    # off does not unsend what other servers already hold.
    refute Fediverse.federated?(page)
    assert Fediverse.ever_federated?(page)
  end

  test "Mastodon client access defaults on and the owner can switch it off", %{conn: conn} do
    {conn, page, _owner} = owned_page(conn)
    assert page.mastodon_clients?

    {:ok, view, html} = live(conn, ~p"/organizations/#{page.slug}/fediverse")
    assert html =~ "mastodon-client-access"

    render_click(view, "toggle-mastodon", %{})

    refute Organizations.get_organization!(page.id).mastodon_clients?
  end

  test "a page without a handle is told to claim one first", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    page = active_organization_for(owner)

    html = conn |> get(~p"/organizations/#{page.slug}/fediverse") |> html_response(200)

    assert html =~ "needs-handle"
    refute html =~ "toggle-fediverse"
  end

  test "a publisher who is not the owner cannot reach it", %{conn: conn} do
    {conn, member} = create_and_login_user(conn)
    owner = insert(:activated_user)
    page = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(page, member, "publisher", owner)

    # Publishers speak for the page; only an owner decides that it appears on
    # servers we do not run.
    assert conn |> get(~p"/organizations/#{page.slug}/fediverse") |> response(404)
  end

  test "the owner sees the Fediverse tab", %{conn: conn} do
    {conn, page, _owner} = owned_page(conn)

    html = conn |> get(~p"/organizations/#{page.slug}/activity") |> html_response(200)
    assert html =~ "#{page.slug}/fediverse"
  end

  test "a publisher does not", %{conn: conn} do
    # Logged in as the publisher, with the page owned by somebody else: they may
    # read the activity list and speak for the page, but the decision to appear
    # on servers we do not run is not theirs.
    {conn, publisher} = create_and_login_user(conn)
    owner = insert(:activated_user)
    page = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(page, publisher, "publisher", owner)

    html = conn |> get(~p"/organizations/#{page.slug}/activity") |> html_response(200)
    refute html =~ "#{page.slug}/fediverse"
  end

  test "the switch page reads as German", %{conn: conn} do
    {conn, page, _owner} = owned_page(conn)

    html =
      conn
      |> Phoenix.ConnTest.recycle()
      |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
      |> get(~p"/organizations/#{page.slug}/fediverse")
      |> html_response(200)

    # The page is written for the owner of a company or an association, not for
    # somebody who already knows the protocol: it says what this does for the
    # organization (reach past vutuv) and never asks them to know the verb
    # "föderieren", which is what every sentence here used to be built on.
    assert html =~ "Auch Menschen ohne vutuv-Konto können dieser Seite folgen"
    assert html =~ "Einschalten"
    assert html =~ "Diese Seite ist auf anderen Netzwerken nicht sichtbar."
    refute html =~ "öderier"

    # The merge filled this one from "Einstellungen durchsuchen" (search
    # settings) and "Fediverse" without the page name; both are named here so
    # they cannot come back.
    refute html =~ "Einstellungen durchsuchen"
  end
end
