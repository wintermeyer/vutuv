defmodule VutuvWeb.OrganizationFollowsMemberTest do
  @moduledoc """
  Following a **member** while speaking for a page (issue #1336) — the control
  that was missing, and the one that matters most: the first source of a page's
  feed is "posts by the members it follows", and until now nothing in the app
  could create such a follow.

  **The header collapses to a plain follow pill while acting as a page**, rather
  than reusing the two-direction relationship pill. That pill's inbound half
  states whether this member follows *you*, and while speaking for a page "you"
  is ambiguous: the member may well follow the page, which is a different
  relation from the one the outbound half controls. Mutual ("vernetzt") is
  between people. One honest control beats a pill that compares two different
  questions.

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

  defp acting_as_page(conn) do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {post(conn, ~p"/organizations/#{organization.slug}/act_as"), organization, owner}
  end

  test "the page follows the member, and their post reaches its feed", %{conn: conn} do
    {conn, organization, _owner} = acting_as_page(conn)
    member = insert(:activated_user)
    {:ok, _post} = Posts.create_post(member, %{body: "Vom Mitglied."})

    {:ok, view, _html} = live(conn, ~p"/#{member}")
    render_click(view, "follow-as-page", %{})

    assert Social.organization_follows?(organization, member)

    feed = conn |> get(~p"/organizations/#{organization.slug}/feed") |> html_response(200)
    assert feed =~ "Vom Mitglied."
  end

  test "the member's own follow state is untouched", %{conn: conn} do
    {conn, organization, owner} = acting_as_page(conn)
    member = insert(:activated_user)

    {:ok, view, _html} = live(conn, ~p"/#{member}")
    render_click(view, "follow-as-page", %{})

    # The follow belongs to whoever is speaking. The person behind the page did
    # not follow anybody, and their own feed must not change.
    assert Social.organization_follows?(organization, member)
    refute Social.user_follows_user?(owner.id, member.id)
  end

  test "and unfollows again from the same pill", %{conn: conn} do
    {conn, organization, _owner} = acting_as_page(conn)
    member = insert(:activated_user)

    {:ok, view, _html} = live(conn, ~p"/#{member}")
    render_click(view, "follow-as-page", %{})
    render_click(view, "unfollow-as-page", %{})

    refute Social.organization_follows?(organization, member)
  end

  test "the relationship pill returns once you stop speaking for the page", %{conn: conn} do
    {conn, _organization, _owner} = acting_as_page(conn)
    member = insert(:activated_user)

    acting = conn |> get(~p"/#{member}") |> html_response(200)
    assert acting =~ "follow-as-page"
    # The two-direction pill asks a question that has no answer for a page.
    refute acting =~ "Folgt dir"
    refute acting =~ "Doesn't follow you"

    conn = delete(conn, ~p"/system/act_as")

    back = conn |> get(~p"/#{member}") |> html_response(200)
    refute back =~ "follow-as-page"
  end

  test "the notification links to the page, not into the handle namespace", %{conn: conn} do
    # Log the member in FIRST: creating a page mails its owner, and `sent_pin/0`
    # reads the oldest email in the mailbox.
    {conn, member} = create_and_login_user(conn)
    page = active_organization_for(insert(:activated_user))
    {:ok, _} = Social.follow_as_organization(page, member)

    html = conn |> get(~p"/notifications") |> html_response(200)

    assert html =~ page.name
    assert html =~ "/organizations/#{page.slug}"
    # `/<slug>` at the root is the member handle namespace, where another member
    # may hold that very word — the link must not be built from the param alone.
    refute html =~ ~s(href="/#{page.slug}")
  end
end
