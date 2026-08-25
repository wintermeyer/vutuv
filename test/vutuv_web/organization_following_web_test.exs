defmodule VutuvWeb.OrganizationFollowingWebTest do
  @moduledoc """
  What a page follows (`/organizations/:slug/following`, issue #1336): the list
  behind the feed, and the only place its team can take a subscription back.
  Publishers only, and deliberately not public — what a page reads is working
  material, and nothing in the issue asks for it to be on show.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Organizations.OrganizationRole
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Tags

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp publishing_page(conn) do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {conn, organization}
  end

  test "the list names every kind the page follows", %{conn: conn} do
    {conn, organization} = publishing_page(conn)

    member = insert(:activated_user, first_name: "Frida", last_name: "Folger")
    tag = insert(:tag)

    other =
      active_organization_for(insert(:activated_user), %{
        "name" => "Zweite AG",
        "website_url" => "https://zweite.example"
      })

    {:ok, _} = Social.follow_as_organization(organization, member)
    {:ok, _} = Social.follow_as_organization(organization, other)
    {:ok, _} = Tags.follow_tag_as_organization(organization, tag.id)

    html = conn |> get(~p"/organizations/#{organization.slug}/following") |> html_response(200)

    assert html =~ "Frida"
    assert html =~ "Zweite AG"
    assert html =~ tag.name
  end

  test "a publisher can take a follow back from here", %{conn: conn} do
    {conn, organization} = publishing_page(conn)
    member = insert(:activated_user)
    tag = insert(:tag)

    {:ok, follow} = Social.follow_as_organization(organization, member)
    {:ok, _} = Tags.follow_tag_as_organization(organization, tag.id)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/following")

    render_click(view, "unfollow", %{"id" => follow.id})
    refute Social.organization_follows?(organization, member)

    render_click(view, "unfollow-tag", %{"id" => tag.id})
    refute Tags.tag_followed_by_organization?(organization, tag)
  end

  test "a publisher can follow and mute a local account from the web", %{conn: conn} do
    {conn, organization} = publishing_page(conn)
    member = insert(:activated_user, username: "local-follow-target")

    {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/following")

    render_submit(view, "follow-local", %{
      "local_follow" => %{"account" => "@local-follow-target"}
    })

    follow = Social.organization_follow_as_organization(organization, member)
    assert follow

    render_click(view, "mute", %{"id" => follow.id})
    assert Repo.reload!(follow).muted

    render_click(view, "unmute", %{"id" => follow.id})
    refute Repo.reload!(follow).muted
  end

  # A member pastes whatever their browser handed them, and the `www.` alias is
  # the same site. Asking `MastodonApi.client_host?/1` rather than a literal
  # list of the two hosts we happen to think of is what keeps the full address
  # on the local branch instead of falling through to the foreign one.
  test "a full local address survives the www. alias and a shouted host", %{conn: conn} do
    {conn, organization} = publishing_page(conn)
    member = insert(:activated_user, username: "www-follow-target")
    host = VutuvWeb.Endpoint.host()

    {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/following")

    render_submit(view, "follow-local", %{
      "local_follow" => %{"account" => "@www-follow-target@www.#{host}"}
    })

    assert Social.organization_follow_as_organization(organization, member)
  end

  # The page is gated before it mounts, but a socket that is already open
  # outlives the grant that opened it, so every write re-asks the role rather
  # than trusting the mount. Calibrated against the un-fixed code: without the
  # check in `with_publisher/2` the follow really does disappear here.
  test "an open page stops mutating after the editorial role is withdrawn", %{conn: conn} do
    {conn, organization} = publishing_page(conn)
    member = insert(:activated_user)
    {:ok, follow} = Social.follow_as_organization(organization, member)
    {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/following")

    Repo.delete!(
      Repo.get_by!(OrganizationRole, organization_id: organization.id, role: "publisher")
    )

    render_click(view, "unfollow", %{"id" => follow.id})

    assert Social.organization_follows?(organization, member)
  end

  test "one page cannot drop another page's follow", %{conn: conn} do
    {conn, organization} = publishing_page(conn)

    other =
      active_organization_for(insert(:activated_user), %{
        "name" => "Zweite AG",
        "website_url" => "https://zweite.example"
      })

    victim = insert(:activated_user)
    {:ok, foreign} = Social.follow_as_organization(other, victim)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/following")
    render_click(view, "unfollow", %{"id" => foreign.id})

    # The handler re-checks the edge belongs to this page rather than trusting
    # the id that came back from the client.
    assert Social.organization_follows?(other, victim)
  end

  test "a role holder who may not speak for the page is turned away", %{conn: conn} do
    {conn, member} = create_and_login_user(conn)
    owner = insert(:activated_user)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, member, "recruiter", owner)

    assert conn |> get(~p"/organizations/#{organization.slug}/following") |> response(404)
  end
end
