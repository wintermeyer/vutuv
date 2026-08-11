defmodule Vutuv.OrganizationPostTagsTest do
  @moduledoc """
  An organization post reaching the tags it files itself under (issues #1334,
  #1336).

  A `#hashtag` in the body already writes its `post_hashtags` row — filing has
  worked all along — but the two queries that *read* those filings inner-join
  `users` on the post's author, so a page could tag a post and the tag page
  would not show it. Filed and invisible is the worst of the two states: the
  data says it is there.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  # A `#hashtag` files a post only against a tag that already exists, so each
  # test mints its own first. Hardcoded literals are safe here because the
  # module is `async: false` (see the tag-uniqueness rule in the Elixir rules).
  defp tag!(slug), do: insert(:tag, name: slug, slug: slug)

  # Filed through the composer's tag field, which is what the tag feed reads.
  defp tagged_organization_post_with_tag(tag_name) do
    {organization, owner} = active_organization()
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

    {:ok, post} =
      Posts.create_organization_post(organization, owner, %{
        body: "Wir bauen etwas.",
        tags: tag_name
      })

    {organization, post}
  end

  defp tagged_organization_post(hashtag) do
    tag!(hashtag)
    {organization, owner} = active_organization()
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

    {:ok, post} =
      Posts.create_organization_post(organization, owner, %{body: "Wir bauen mit ##{hashtag}."})

    {organization, post}
  end

  defp tag_post_ids(tag) do
    tag |> Posts.tag_posts_query() |> Repo.all() |> Enum.map(& &1.id)
  end

  test "the post is filed under its hashtag and the tag page shows it" do
    {_organization, post} = tagged_organization_post("orgtagtest")
    tag = Repo.get_by!(Tag, slug: "orgtagtest")

    # Filing already worked; being read back is what did not.
    assert tag
    assert post.id in tag_post_ids(tag)
  end

  test "a frozen page takes its tagged posts off the tag page" do
    {organization, post} = tagged_organization_post("frozentagtest")
    tag = Repo.get_by!(Tag, slug: "frozentagtest")

    assert post.id in tag_post_ids(tag)

    {:ok, _} = Organizations.admin_set_frozen(organization, true)
    refute post.id in tag_post_ids(tag)
  end

  test "a followed tag brings a page's post into the feed" do
    # An explicit tag, not a body hashtag: the tag FEED source matches
    # `post_tags` only, while the tag PAGE unions in `post_hashtags` too. That
    # split is pre-existing and member posts share it, so it is not this
    # milestone's to change — but it is why this test files the tag properly.
    tag = tag!("feedtagtest")
    {_organization, post} = tagged_organization_post_with_tag("feedtagtest")
    reader = insert(:activated_user)
    {:ok, _} = Tags.follow_tag(reader, tag.id)

    ids = reader |> Posts.feed_page() |> Map.fetch!(:entries) |> Enum.map(& &1.post.id)
    assert post.id in ids
  end

  test "a page the reader already follows is not shown twice by its tag" do
    tag = tag!("dupetagtest")
    {organization, post} = tagged_organization_post_with_tag("dupetagtest")
    reader = insert(:activated_user)
    {:ok, _} = Tags.follow_tag(reader, tag.id)
    {:ok, _} = Vutuv.Social.follow_organization(reader, organization)

    ids = reader |> Posts.feed_page() |> Map.fetch!(:entries) |> Enum.map(& &1.post.id)
    assert Enum.count(ids, &(&1 == post.id)) == 1
  end

  test "member posts still reach their tag page" do
    tag!("membertagtest")
    author = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "Ich baue mit #membertagtest."})
    tag = Repo.get_by!(Tag, slug: "membertagtest")

    assert post.id in tag_post_ids(tag)
  end
end
