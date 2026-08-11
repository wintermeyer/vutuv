defmodule Vutuv.OrganizationTagFollowTest do
  @moduledoc """
  A page follows a **tag** (issue #1336), so its feed carries a topic and not
  only the people and pages it follows. Third table to take the nullable pair,
  and by now the shape is routine.

  Stefan's "tags and remote accounts" splits here: a page following a *remote*
  account is not just another table. The fediverse actor is keyed to a member
  and carries the keypair that signs the outgoing Follow, so a page cannot send
  one until it has an actor document of its own — #1334's fediverse half.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Tags
  alias Vutuv.Tags.TagFollow

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp page, do: active_organization_for(insert(:activated_user))

  test "the database refuses a row naming both or neither follower" do
    tag = insert(:tag)
    member = insert(:activated_user)
    organization = page()

    assert_raise Ecto.ConstraintError, ~r/tag_follows_exactly_one_follower/, fn ->
      Repo.insert!(%TagFollow{
        user_id: member.id,
        organization_id: organization.id,
        tag_id: tag.id
      })
    end

    assert_raise Ecto.ConstraintError, ~r/tag_follows_exactly_one_follower/, fn ->
      Repo.insert!(%TagFollow{tag_id: tag.id})
    end
  end

  test "a page follows and unfollows a tag, idempotently" do
    organization = page()
    tag = insert(:tag)

    assert {:ok, follow} = Tags.follow_tag_as_organization(organization, tag.id)
    assert follow.organization_id == organization.id
    assert Tags.tag_followed_by_organization?(organization, tag)

    # `[user_id, tag_id]` cannot police this: both rows leave user_id NULL.
    assert {:ok, same} = Tags.follow_tag_as_organization(organization, tag.id)
    assert same.id == follow.id

    assert Tags.unfollow_tag_as_organization(organization, tag) == 1
    refute Tags.tag_followed_by_organization?(organization, tag)
    assert Tags.unfollow_tag_as_organization(organization, tag) == 0
  end

  test "the member's own subscriptions are untouched by a page's" do
    organization = page()
    member = insert(:activated_user)
    tag = insert(:tag)

    {:ok, _} = Tags.follow_tag_as_organization(organization, tag.id)

    refute Tags.tag_followed?(member, tag)
    assert Tags.followed_tag_ids(member) == []
    assert Tags.organization_followed_tag_ids(organization) == [tag.id]

    # The tag's public aggregate counts both kinds: each is a subscription to
    # the same topic.
    assert Tags.tag_follower_count(tag) == 1
  end

  test "a followed tag's posts reach the page's feed" do
    organization = page()
    tag = insert(:tag)
    author = insert(:activated_user)

    {:ok, post} = Posts.create_post(author, %{body: "Zum Thema.", tags: [tag.name]})
    {:ok, _} = Tags.follow_tag_as_organization(organization, tag.id)

    ids =
      organization
      |> Posts.organization_feed_page()
      |> Map.fetch!(:entries)
      |> Enum.map(& &1.post.id)

    assert post.id in ids
  end

  test "a restricted post with a followed tag still does not reach the page" do
    organization = page()
    tag = insert(:tag)
    author = insert(:activated_user)

    {:ok, hidden} =
      Posts.create_post(author, %{
        body: "Nur für Follower.",
        tags: [tag.name],
        denials: [%{"wildcard" => "non_followers"}]
      })

    {:ok, _} = Tags.follow_tag_as_organization(organization, tag.id)

    ids =
      organization
      |> Posts.organization_feed_page()
      |> Map.fetch!(:entries)
      |> Enum.map(& &1.post.id)

    refute hidden.id in ids
  end
end
