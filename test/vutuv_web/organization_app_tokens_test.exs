defmodule VutuvWeb.OrganizationAppTokensTest do
  @moduledoc """
  The owner's oversight of the app tokens issued for their page
  (`/organizations/:slug/apps`).

  A member turns the page's app access into a credential of their own accord,
  and until now only that member could see or withdraw it — so an owner could
  not tell who was reaching the page from an app, let alone stop one.

  `async: false` for the same reason as `organization_apps_switch_test.exs`: the
  organization helpers flip the global `:verify_organization_domains` flag and
  the DNS-resolver stub beside it.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.ApiAuth
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

  defp owned_page_with_apps_on(conn) do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    {:ok, organization} = Organizations.set_mastodon_clients(organization, true)

    {conn, organization, owner}
  end

  defp issue(organization, user, user_agent \\ nil) do
    app = insert(:oauth_app, user: nil, protocol: "mastodon", name: "Ivory")

    insert(:api_token,
      user: user,
      app: app,
      organization: organization,
      kind: "access",
      name: nil,
      scopes: ["read"],
      expires_at: nil,
      user_agent: user_agent,
      token_hash: ApiAuth.hash_token("vutuv_at_" <> ApiAuth.random_token())
    )
  end

  test "lists who is signed in as the page, with device and time", %{conn: conn} do
    {conn, organization, _owner} = owned_page_with_apps_on(conn)
    issuer = insert(:activated_user, first_name: "Ada", last_name: "Lovelace")
    token = issue(organization, issuer, "Ivory/1.0 (iPhone; iOS 18.2)")

    {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.slug}/apps")

    assert html =~ "Ada Lovelace"
    assert html =~ "iPhone"
    assert html =~ ~s(data-app-token="#{token.id}")
  end

  test "a client string it cannot place is called unknown, never guessed", %{conn: conn} do
    {conn, organization, _owner} = owned_page_with_apps_on(conn)
    issue(organization, insert(:activated_user), "some-http-library/2.1")

    {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.slug}/apps")

    assert html =~ "unknown device"
  end

  test "the filter narrows the list to one member", %{conn: conn} do
    {conn, organization, _owner} = owned_page_with_apps_on(conn)
    issue(organization, insert(:activated_user, first_name: "Zoraida"))
    issue(organization, insert(:activated_user, first_name: "Bartholomew"))

    {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/apps")

    html = view |> form("form[phx-change=filter]", %{"query" => "zorai"}) |> render_change()

    assert html =~ "Zoraida"
    refute html =~ "Bartholomew"
  end

  test "the switch's confirmation counts every token, not the filtered rows", %{conn: conn} do
    # The switch withdraws all of them, so its confirmation may not read the
    # list's filtered total: narrowed to one colleague it promised that "the
    # one app token" was going, with two more behind it. Pointing `data-confirm`
    # back at `@tokens.total` turns this red.
    {conn, organization, _owner} = owned_page_with_apps_on(conn)
    issue(organization, insert(:activated_user, first_name: "Zoraida"))
    issue(organization, insert(:activated_user, first_name: "Bartholomew"))
    issue(organization, insert(:activated_user, first_name: "Cornelius"))

    {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/apps")

    html = view |> form("form[phx-change=filter]", %{"query" => "zorai"}) |> render_change()

    assert html =~ "All 3 app tokens issued for this page are withdrawn"
    refute html =~ "The one app token issued for this page is withdrawn"
    # The list still says what the filter found.
    assert html =~ "Zoraida"
    refute html =~ "Bartholomew"
  end

  test "an owner withdraws one token and the rest stay", %{conn: conn} do
    {conn, organization, _owner} = owned_page_with_apps_on(conn)
    doomed = issue(organization, insert(:activated_user))
    kept = issue(organization, insert(:activated_user))

    {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/apps")

    html = view |> element(~s([data-app-token="#{doomed.id}"] button)) |> render_click()

    refute html =~ ~s(data-app-token="#{doomed.id}")
    assert html =~ ~s(data-app-token="#{kept.id}")
    assert ApiAuth.count_organization_tokens(organization) == 1
  end

  test "turning app access off withdraws every token", %{conn: conn} do
    {conn, organization, _owner} = owned_page_with_apps_on(conn)
    for _ <- 1..3, do: issue(organization, insert(:activated_user))

    {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/apps")

    # Leaving them alive would make the switch a lie: they stop working while it
    # is off and come back the moment somebody turns it on again.
    view |> element("#mastodon-client-access button") |> render_click()

    assert ApiAuth.count_organization_tokens(organization) == 0
    refute Organizations.get_organization!(organization.id).mastodon_clients?
  end

  test "the confirmation names how many are about to go", %{conn: conn} do
    {conn, organization, _owner} = owned_page_with_apps_on(conn)
    for _ <- 1..2, do: issue(organization, insert(:activated_user))

    {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.slug}/apps")

    # Nothing is destroyed without the owner having been told how much.
    assert html =~ "All 2 app tokens"
  end

  test "the German page says it in German", %{conn: conn} do
    {conn, organization, _owner} = owned_page_with_apps_on(conn)
    issue(organization, insert(:activated_user), "Ivory/1.0 (iPhone; iOS 18.2)")

    # vutuv is a German site, and `?lang=de` without the header renders English
    # — so the header is what a locale test has to carry. Asserted by name
    # because every one of these strings was fuzzy-filled by
    # `gettext.extract --merge`: "Connected on" came back as "Vernetzt", the
    # word this project uses for a mutual follow.
    {:ok, _view, html} =
      conn
      |> recycle()
      |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
      |> live(~p"/organizations/#{organization.slug}/apps")

    assert html =~ "Genutzte App-Zugänge"
    assert html =~ "Ausgestellt von"
    assert html =~ "Entziehen"
  end

  # The page is gated before it mounts, but a socket outlives the grant that
  # opened it, so the write re-asks. Calibrated against the un-checked handler:
  # without the `owner?/2` guard the token really does die here.
  test "an open page stops withdrawing after the ownership is withdrawn", %{conn: conn} do
    {conn, organization, _owner} = owned_page_with_apps_on(conn)
    token = issue(organization, insert(:activated_user))

    {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/apps")

    Repo.delete!(Repo.get_by!(OrganizationRole, organization_id: organization.id, role: "owner"))
    render_click(view, "revoke", %{"id" => token.id})

    assert ApiAuth.count_organization_tokens(organization) == 1
  end
end
