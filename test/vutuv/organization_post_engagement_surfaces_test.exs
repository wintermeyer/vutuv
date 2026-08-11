defmodule Vutuv.OrganizationPostEngagementSurfacesTest do
  @moduledoc """
  Where an organization post shows up **after** somebody engages with it
  (issues #1334, #1336).

  v7.242.1 made liking, reposting and bookmarking one work. What it did not
  check is whether the result then appears anywhere, and two queries inner-join
  `users` on the post's author — so the acts succeeded and their consequences
  vanished. Silent in both cases: an empty saved list looks like an empty saved
  list.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use Vutuv.DataCase, async: false

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

  defp organization_post(body \\ "Von der Seite.") do
    {organization, owner} = active_organization()
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {:ok, post} = Posts.create_organization_post(organization, owner, %{body: body})
    {organization, post}
  end

  defp feed_ids(member) do
    member |> Posts.feed_page() |> Map.fetch!(:entries) |> Enum.map(& &1.post.id)
  end

  test "a repost of an organization post reaches the reposter's followers" do
    {_organization, post} = organization_post()
    reposter = insert(:activated_user)
    reader = insert(:activated_user)
    {:ok, _} = Social.follow(reader, reposter.id)

    :ok = Posts.repost_post(reposter, post)

    # Reposting is how a member passes a page's news on. Without it the act
    # succeeded and reached nobody.
    assert post.id in feed_ids(reader)
    # …and the reposter sees their own.
    assert post.id in feed_ids(reposter)
  end

  test "a frozen page's post is not amplified by a repost" do
    {organization, post} = organization_post()
    reposter = insert(:activated_user)
    reader = insert(:activated_user)
    {:ok, _} = Social.follow(reader, reposter.id)
    :ok = Posts.repost_post(reposter, post)

    assert post.id in feed_ids(reader)

    {:ok, _} = Organizations.admin_set_frozen(organization, true)
    refute post.id in feed_ids(reader)
  end

  test "a bookmarked organization post appears on the saved page" do
    {organization, post} = organization_post("Zum Merken.")
    member = insert(:activated_user)

    :ok = Posts.bookmark_post(member, post)

    ids = member |> Posts.bookmarked_posts_page() |> Map.fetch!(:entries) |> Enum.map(& &1.id)
    assert post.id in ids

    # …and it is findable there by the page's name, not only by its body.
    found =
      member
      |> Posts.bookmarked_posts_page(search: organization.name)
      |> Map.fetch!(:entries)
      |> Enum.map(& &1.id)

    assert post.id in found
  end

  test "the saved page still lists a bookmarked member post" do
    author = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "Von einem Menschen."})
    member = insert(:activated_user)

    :ok = Posts.bookmark_post(member, post)

    ids = member |> Posts.bookmarked_posts_page() |> Map.fetch!(:entries) |> Enum.map(& &1.id)
    assert post.id in ids
  end
end
