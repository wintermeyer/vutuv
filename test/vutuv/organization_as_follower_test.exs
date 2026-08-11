defmodule Vutuv.OrganizationAsFollowerTest do
  @moduledoc """
  A page can follow (issue #1336). The column shipped ahead of its writer in
  v7.248.1; this is the writer, and the readers Stefan decided must now show
  such a follow.

  **The decision the sweep rests on:** a page that follows you appears in your
  followers list and your follower count. Hiding it would make the number lie,
  and it would let a page know something about you that you cannot see. That is
  what turns the follower-side inner joins into left joins — and every one of
  them is a place a nil `%User{}` could reach a rendered row, so each is
  asserted here rather than trusted.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Accounts.User
  alias Vutuv.Organizations.Organization
  alias Vutuv.Social

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp second_page do
    active_organization_for(insert(:activated_user), %{
      "name" => "Zweite AG",
      "website_url" => "https://zweite.example"
    })
  end

  describe "a page follows" do
    test "a member, once" do
      page = active_organization_for(insert(:activated_user))
      member = insert(:activated_user)

      assert {:ok, follow} = Social.follow_as_organization(page, member)
      assert follow.follower_organization_id == page.id
      assert follow.followee_id == member.id
      assert Social.organization_follows?(page, member)

      # Idempotent like its member twin: the control is a toggle, so a double
      # click must return the edge rather than read as a failure.
      assert {:ok, same} = Social.follow_as_organization(page, member)
      assert same.id == follow.id
    end

    test "another page, but never itself" do
      page = second_page()
      other = active_organization_for(insert(:activated_user))

      assert {:ok, _} = Social.follow_as_organization(page, other)
      assert Social.organization_follows?(page, other)

      assert {:error, changeset} = Social.follow_as_organization(page, page)
      refute changeset.valid?
    end

    test "and unfollows again" do
      page = active_organization_for(insert(:activated_user))
      member = insert(:activated_user)

      {:ok, _} = Social.follow_as_organization(page, member)
      assert :ok = Social.unfollow_as_organization(page, member)
      refute Social.organization_follows?(page, member)

      # Idempotent both ways.
      assert :ok = Social.unfollow_as_organization(page, member)
    end
  end

  describe "the member being followed sees it" do
    test "the header count adds the page, and the two sections sum to it" do
      page = active_organization_for(insert(:activated_user))
      person = insert(:activated_user)
      member = insert(:activated_user)

      {:ok, _} = Social.follow(person, member.id)
      {:ok, _} = Social.follow_as_organization(page, member)

      # The profile header counts both kinds; the Followers page splits them,
      # exactly as the Following page does, because `card_list` renders people
      # and a page has a logo and neither work history nor tags.
      assert Social.follower_count(member) == 2
      assert Social.social_counts(member).followers == 2

      people = Social.follows_page(member, :followers, %{})
      assert people.total == 1
      assert [%User{id: id}] = people.users
      assert id == person.id

      assert Social.follower_organization_count(member) == 1
      assert [{_follow_id, %Organization{id: page_id}}] = Social.follower_organizations(member)
      assert page_id == page.id
    end

    test "a frozen page is neither shown nor counted" do
      page = active_organization_for(insert(:activated_user))
      member = insert(:activated_user)

      {:ok, _} = Social.follow_as_organization(page, member)
      assert Social.follower_count(member) == 1

      {:ok, _} = Vutuv.Organizations.admin_set_frozen(page, true)

      # The page gate mirrors the member gate: a follower nobody may look at is
      # not shown and not counted. `status` stays "active" through a freeze, so
      # a gate that only reads it would still show this one.
      assert Social.follower_count(member) == 0
      assert Social.follower_organizations(member) == []
    end
  end

  describe "what a page follows" do
    test "is listed on the page with its own count" do
      page = active_organization_for(insert(:activated_user))
      member = insert(:activated_user)
      other = second_page()

      {:ok, _} = Social.follow_as_organization(page, member)
      {:ok, _} = Social.follow_as_organization(page, other)

      assert Social.organization_followee_count(page) == 2

      followees = Social.organization_followees(page)
      assert Enum.any?(followees, &match?({_id, %User{id: id}} when id == member.id, &1))
      assert Enum.any?(followees, &match?({_id, %Organization{id: id}} when id == other.id, &1))
    end
  end
end
