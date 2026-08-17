defmodule VutuvWeb.OrganizationActivityWebTest do
  @moduledoc """
  The organization activity page (issue #1336). `async: false` because the
  organization helpers flip the global `:verify_organization_domains` flag.
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

  test "the team sees what happened, marked new, and opening it clears the marker",
       %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    follower = insert(:activated_user, first_name: "Frida", last_name: "Folger")
    {:ok, _} = Social.follow_organization(follower, organization)

    {:ok, view, html} = live(conn, ~p"/organizations/#{organization.slug}/activity")

    assert html =~ "Frida Folger"
    # Nobody had looked, so the entry is marked new …
    assert has_element?(view, "[data-activity-new]")

    # … and the marker was stamped for the whole team, not for this member.
    assert Organizations.get_organization!(organization.id).activity_read_at

    assert Organizations.unread_activity_count(Organizations.get_organization!(organization.id)) ==
             0

    # A second visit shows the same entry without the new mark.
    {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}/activity")
    refute has_element?(view, "[data-activity-new]")
  end

  test "an entry that points at a post renders its link", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {:ok, post} = Vutuv.Posts.create_organization_post(organization, owner, %{body: "Gefällt?"})
    :ok = Vutuv.Posts.like_post(insert(:activated_user), post)

    # `Posts.path/1` matches on the preloaded author, so an entry whose post
    # arrived from a bare query would raise here rather than render.
    {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.slug}/activity")

    assert html =~ Vutuv.Posts.path(post)
  end

  test "an admin who is not a publisher still reaches it", %{conn: conn} do
    {conn, admin} = create_and_login_user(conn)
    owner = insert(:activated_user)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, admin, "admin", owner)

    # Deliberately not gated on `publisher`: this is news ABOUT the page, not
    # speaking FOR it, so it follows team membership.
    assert conn
           |> get(~p"/organizations/#{organization.slug}/activity")
           |> html_response(200) =~ "Activity"
  end

  test "the member's own organizations list shows the count and links to it", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)

    # Nothing yet: no badge, so the row stays quiet.
    refute conn |> get(~p"/settings/organizations") |> html_response(200) =~
             "data-organization-activity"

    {:ok, _} = Social.follow_organization(insert(:activated_user), organization)

    html = conn |> get(~p"/settings/organizations") |> html_response(200)
    assert html =~ "data-organization-activity"
    assert html =~ "/organizations/#{organization.slug}/activity"
  end

  test "an answer to one of the page's posts reads correctly in German", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {:ok, post} = Vutuv.Posts.create_organization_post(organization, owner, %{body: "Hallo."})
    reader = insert(:activated_user, first_name: "Rita", last_name: "Leserin")
    {:ok, _reply} = Vutuv.Posts.create_reply(reader, post, %{body: "Antwort"})

    # Asserted by name and in German on purpose: `gettext.extract --merge`
    # fuzzy-filled this brand-new msgid with "hat einen Beitrag geteilt"
    # (*shared* a post), which nothing in an English test would ever have
    # noticed.
    html =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de")
      |> get(~p"/organizations/#{organization.slug}/activity")
      |> html_response(200)

    assert html =~ "Rita Leserin hat auf einen Beitrag geantwortet."
  end

  test "someone outside the team gets a 404", %{conn: conn} do
    {stranger_conn, _stranger} = create_and_login_user(conn)
    owner = insert(:activated_user)
    organization = active_organization_for(owner)

    stranger_conn
    |> get(~p"/organizations/#{organization.slug}/activity")
    |> response(404)
  end
end
