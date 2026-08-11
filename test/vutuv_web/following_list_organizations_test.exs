defmodule VutuvWeb.FollowingListOrganizationsTest do
  @moduledoc """
  A member's "Following" page left out the pages they follow, so once you
  followed one the only way to unfollow it was to find it again. Same shape as
  the two fixed in v7.247.10: the list and its count reach the followee through
  an INNER JOIN to `users`, and an organization follow has `followee_id IS NULL`.

  Pages get their own section rather than a `card_list` row — a page has a logo
  and neither work history nor tags — so the assertions here are about the
  section, the count, the agent-format sibling and the unfollow control.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations.Organization
  alias Vutuv.Repo
  alias Vutuv.Social

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp member_following_a_page do
    owner = insert(:activated_user)
    organization = active_organization_for(owner)
    member = insert(:activated_user)
    {:ok, follow} = Social.follow_organization(member, organization)
    {member, organization, follow}
  end

  test "the Following page names the page and links to it", %{conn: conn} do
    {member, organization, _follow} = member_following_a_page()

    html = conn |> get(~p"/#{member}/following") |> html_response(200)

    assert html =~ organization.name
    assert html =~ "/organizations/#{organization.slug}"
  end

  test "a followed page counts towards Following", %{conn: _conn} do
    {member, _organization, _follow} = member_following_a_page()

    # The profile header's "Following" figure reads this, so leaving pages out
    # made the number disagree with what the member had actually done.
    assert Social.followee_count(member) == 1
    assert Social.social_counts(member).followees == 1
  end

  test "the member can unfollow the page from their own list", %{conn: conn} do
    # Log in FIRST: creating a page mails its owner, and `sent_pin/0` reads the
    # oldest email in the mailbox, so the notice would be taken for the PIN.
    {conn, member} = create_and_login_user(conn)
    owner = insert(:activated_user)
    organization = active_organization_for(owner)
    {:ok, follow} = Social.follow_organization(member, organization)

    html = conn |> get(~p"/#{member}/following") |> html_response(200)
    assert html =~ ~s(/follows/#{follow.id})

    conn |> delete(~p"/follows/#{follow.id}") |> response(302)
    refute Social.follows_organization?(member, organization)
  end

  test "a page nobody may see yet is left out", %{conn: conn} do
    owner = insert(:activated_user)
    organization = active_organization_for(owner)
    member = insert(:activated_user)
    {:ok, _} = Social.follow_organization(member, organization)

    {:ok, _frozen} =
      organization
      |> Organization.status_changeset("frozen")
      |> Repo.update()

    html = conn |> get(~p"/#{member}/following") |> html_response(200)

    refute html =~ organization.name
    assert Social.followee_count(member) == 0
  end

  test "every agent-format sibling carries the followed page", %{conn: conn} do
    {member, organization, _follow} = member_following_a_page()

    json = conn |> get(~p"/#{member}/following.json") |> json_response(200)
    assert Enum.any?(json["organizations"] || [], &(&1["name"] == organization.name))

    # The four formats render one doc map, so a key added for JSON alone is
    # drift: .md and .txt build their bodies field by field and would have gone
    # on listing people only.
    for extension <- ~w(md txt xml) do
      body = conn |> get("/#{member.username}/following.#{extension}") |> response(200)
      assert body =~ organization.name, "#{extension} left the followed page out"
    end
  end
end
