defmodule Vutuv.OrganizationFollowerRowsTest do
  @moduledoc """
  `follows.follower_id` is nullable now, so a row can name an **organization**
  as the follower (issue #1336). Nothing in the app writes one yet — this is the
  expand step — so these tests insert them directly and then ask every reader of
  the follower side whether it still answers correctly.

  That order is the whole point. Widening `posts.user_id` produced eleven silent
  failures because the readers met the new row shape in production before anyone
  had looked at them. Here they meet it in a test first.

  Three shapes to catch, the same three that milestone taught us:

    1. `NOT IN` / an id list over the now-nullable column — one NULL makes the
       predicate false for every row, or puts a nil into a recipient list;
    2. an INNER JOIN to `users` on the follower side — the row vanishes, so a
       count and its list stop agreeing;
    3. reading `follow.follower` — nil, which raises somewhere downstream.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Social.Follow

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  # A page following a member — the row no writer produces yet.
  defp page_follows(member) do
    owner = insert(:activated_user)
    organization = active_organization_for(owner)

    follow =
      Repo.insert!(%Follow{follower_organization_id: organization.id, followee_id: member.id})

    {organization, follow}
  end

  describe "the database refuses a row that names neither or both followers" do
    test "both sides set" do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      member = insert(:activated_user)

      assert_raise Ecto.ConstraintError, ~r/follows_exactly_one_follower/, fn ->
        Repo.insert!(%Follow{
          follower_id: member.id,
          follower_organization_id: organization.id,
          followee_id: insert(:activated_user).id
        })
      end
    end

    test "neither side set" do
      assert_raise Ecto.ConstraintError, ~r/follows_exactly_one_follower/, fn ->
        Repo.insert!(%Follow{followee_id: insert(:activated_user).id})
      end
    end

    test "the same page cannot follow the same member twice" do
      member = insert(:activated_user)
      {organization, _follow} = page_follows(member)

      # `[follower_id, followee_id]` cannot enforce this: both rows leave
      # follower_id NULL and Postgres treats NULLs as distinct.
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Follow{follower_organization_id: organization.id, followee_id: member.id})
      end
    end
  end

  describe "the readers of the follower side" do
    test "a member's follower count and list now show the page" do
      member = insert(:activated_user)
      person = insert(:activated_user)
      {:ok, _} = Social.follow(person, member.id)
      {_organization, _follow} = page_follows(member)

      # This test used to assert the opposite, and the reversal is Stefan's
      # call (v7.248.3): a page that follows you is counted and shown, because
      # hiding it makes the number lie and lets a page know something about you
      # that you cannot see. The follower-side joins are LEFT joins now.
      #
      # The header counts both kinds; the page splits them into two sections,
      # so `follows_page/3` still answers with people alone. The full behaviour
      # lives in organization_as_follower_test.exs — what this file still owns
      # is that a raw row inserted straight into the table behaves the same as
      # one the writer made.
      assert Social.follower_count(member) == 2
      assert Social.follower_organization_count(member) == 1

      page = Social.follows_page(member, :followers, %{})
      assert page.total == 1
      assert [%Vutuv.Accounts.User{id: id}] = page.users
      assert id == person.id
    end

    test "the member's own follow lists are unaffected" do
      member = insert(:activated_user)
      {_organization, _follow} = page_follows(member)

      # Nothing about being followed by a page changes what the member follows.
      assert Social.followee_count(member) == 0
      refute Social.follows_anyone?(member)
    end

    test "publishing and deleting a post survives a page among the followers" do
      member = insert(:activated_user)
      {_organization, _follow} = page_follows(member)

      # Shape 1, the Elixir twin: the broadcast recipients come from
      # `select: c.follower_id` over this member's followers, so a page in that
      # set puts a nil in the list. `Activity.broadcast/2` absorbs a nil by
      # design, which is exactly why this has to be asserted from the outside —
      # the damage would be a wasted call today and a crash the first time some
      # other consumer of that list is less forgiving.
      {:ok, post} = Vutuv.Posts.create_post(member, %{body: "Trotz Seite."})
      assert {:ok, _} = Vutuv.Posts.delete_post(post)
    end

    test "the follow-back suggestions skip a page" do
      member = insert(:activated_user)
      {_organization, _follow} = page_follows(member)

      # Shape 3: this builds `%User{}` rows out of the follower side, so a page
      # must be left out rather than surface as a nil row.
      assert Social.followers_to_follow_back(member.id, 5) == []
    end

    test "the most-followed listing still ranks members" do
      member = insert(:activated_user)
      person = insert(:activated_user)
      {:ok, _} = Social.follow(person, member.id)
      {_organization, _follow} = page_follows(member)

      assert Enum.any?(Social.most_followed_users(10), &(&1.id == member.id))
    end
  end
end
