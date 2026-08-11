defmodule VutuvWeb.OrganizationFeedWebTest do
  @moduledoc """
  `/organizations/:slug/feed` (issue #1336) is **publishers only**, where the
  activity list beside it takes any role holder. The difference is deliberate:
  activity is news about the page, this is the page's own reading, which is part
  of speaking for it.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Social

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  test "a publisher reads what the page follows", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

    author = insert(:activated_user, first_name: "Frida", last_name: "Folger")
    {:ok, _} = Posts.create_post(author, %{body: "Ein gefolgter Beitrag."})
    {:ok, _} = Social.follow_as_organization(organization, author)

    html = conn |> get(~p"/organizations/#{organization.slug}/feed") |> html_response(200)

    assert html =~ "Ein gefolgter Beitrag."
    assert html =~ "Frida"
  end

  test "a role holder who may not speak for the page is turned away", %{conn: conn} do
    {conn, member} = create_and_login_user(conn)
    owner = insert(:activated_user)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, member, "recruiter", owner)

    # A recruiter may manage postings and read the activity list, but the page's
    # own reading is not theirs.
    assert conn |> get(~p"/organizations/#{organization.slug}/feed") |> response(404)
  end

  test "the Feed tab shows only to a publisher", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)

    # The owner has not granted themselves `publisher` — the roles are separate
    # by design (#1333), so the tab must not appear on the activity page either.
    activity = conn |> get(~p"/organizations/#{organization.slug}/activity") |> html_response(200)
    refute activity =~ "#{organization.slug}/feed"

    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

    with_tab = conn |> get(~p"/organizations/#{organization.slug}/activity") |> html_response(200)
    assert with_tab =~ "#{organization.slug}/feed"
  end

  test "acting as a page, following another page fills the first page's feed", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    reader = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(reader, owner, "publisher", owner)

    other_owner = insert(:activated_user)

    other =
      active_organization_for(other_owner, %{
        "name" => "Zweite AG",
        "website_url" => "https://zweite.example"
      })

    {:ok, _} = Organizations.add_role(other, other_owner, "publisher", other_owner)
    {:ok, _} = Posts.create_organization_post(other, other_owner, %{body: "Von der Zweiten."})

    # Speak as the reader page, then press Follow on the other page: the follow
    # belongs to the page, not to the person, so it is the page's feed that
    # fills. This is the one control that calls follow_as_organization/2.
    conn = post(conn, ~p"/organizations/#{reader.slug}/act_as")

    {:ok, view, _html} = live(conn, ~p"/organizations/#{other.slug}")
    render_click(view, "toggle-follow", %{})

    assert Social.organization_follows?(reader, other)

    feed = conn |> get(~p"/organizations/#{reader.slug}/feed") |> html_response(200)
    assert feed =~ "Von der Zweiten."
  end
end
