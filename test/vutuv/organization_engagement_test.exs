defmodule Vutuv.OrganizationEngagementTest do
  @moduledoc """
  A page likes, bookmarks and reposts (issue #1336's last loose end).

  It read its feed from v7.242.0 on but could not react in it, which made the
  page a spectator in a room it was otherwise a full member of.

  Every act follows the shape the rest of this milestone settled on: the act
  belongs to the **page**, `acting_user_id` records the member who pressed the
  button and is never shown, and the right to press it follows the **role**, so
  it is asked live rather than trusted from whatever the session says.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Posts.{PostBookmark, PostLike, PostRepost}
  alias Vutuv.Repo

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp page_with_publisher do
    owner = insert(:activated_user)
    page = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)
    {page, owner}
  end

  defp a_post do
    author = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "Hallo Welt"})
    {post, author}
  end

  test "the database refuses a row naming both actors or neither" do
    {page, _owner} = page_with_publisher()
    {post, author} = a_post()

    for schema <- [PostLike, PostBookmark, PostRepost] do
      assert_raise Ecto.ConstraintError, ~r/exactly_one_actor/, fn ->
        Repo.insert!(
          struct(schema, post_id: post.id, user_id: author.id, organization_id: page.id)
        )
      end

      assert_raise Ecto.ConstraintError, ~r/exactly_one_actor/, fn ->
        Repo.insert!(struct(schema, post_id: post.id))
      end
    end
  end

  test "a page likes a post once, in its own name" do
    {page, owner} = page_with_publisher()
    {post, _author} = a_post()

    assert :ok = Posts.like_post(page, owner, post)
    assert :ok = Posts.like_post(page, owner, post)

    assert [like] = Repo.all(from(l in PostLike, where: l.post_id == ^post.id))
    assert like.organization_id == page.id
    assert is_nil(like.user_id)
    # Who pressed it is kept, the same split posts and messages make.
    assert like.acting_user_id == owner.id

    engagement = Posts.post_engagement(post.id, page)
    assert engagement.likes == 1
    assert engagement.liked?
  end

  test "the page's own count is not inflated by its own like" do
    {page, owner} = page_with_publisher()
    {:ok, post} = Posts.create_organization_post(page, owner, %{body: "Unser Beitrag"})

    # The self-vote rule is about the AUTHOR, and for an organization post the
    # author is the page.
    assert {:error, :self} = Posts.like_post(page, owner, post)

    # Its publishers are refused too, and that is the pre-existing rule rather
    # than a new one: `author?/2` already treats anybody who may currently speak
    # for the page as the post's author, which is what gives them edit and
    # delete rights. A publisher liking the page's post is the same self-vote.
    assert {:error, :self} = Posts.like_post(owner, post)
    assert Posts.post_engagement(post.id, page).likes == 0

    # Somebody outside the team is an ordinary reader.
    outsider = insert(:activated_user)
    assert :ok = Posts.like_post(outsider, post)
    assert Posts.post_engagement(post.id, outsider).likes == 1
  end

  test "somebody who may not speak for the page cannot act as it" do
    {page, _owner} = page_with_publisher()
    {post, _author} = a_post()
    stranger = insert(:activated_user)

    assert {:error, :not_allowed} = Posts.like_post(page, stranger, post)
    assert {:error, :not_allowed} = Posts.bookmark_post(page, stranger, post)
    assert {:error, :not_allowed} = Posts.repost_post(page, stranger, post)

    assert Posts.post_engagement(post.id, page).likes == 0
  end

  test "the page unlikes, unbookmarks and unreposts" do
    {page, owner} = page_with_publisher()
    {post, _author} = a_post()

    assert :ok = Posts.like_post(page, owner, post)
    assert :ok = Posts.bookmark_post(page, owner, post)
    assert :ok = Posts.repost_post(page, owner, post)

    engagement = Posts.post_engagement(post.id, page)
    assert engagement.liked?
    assert engagement.bookmarked?
    assert engagement.reposted?

    :ok = Posts.unlike_post(page, post)
    :ok = Posts.unbookmark_post(page, post)
    :ok = Posts.unrepost_post(page, post)

    engagement = Posts.post_engagement(post.id, page)
    refute engagement.liked?
    refute engagement.bookmarked?
    refute engagement.reposted?
  end

  test "a page's like and a member's like of the same post both count" do
    {page, owner} = page_with_publisher()
    {post, _author} = a_post()
    member = insert(:activated_user)

    assert :ok = Posts.like_post(page, owner, post)
    assert :ok = Posts.like_post(member, post)

    # The old unique index is `(post_id, user_id)`, and Postgres treats NULLs as
    # distinct there - so without the second index on `(post_id,
    # organization_id)` a page could like the same post without limit.
    assert Posts.post_engagement(post.id, member).likes == 2
  end

  test "the author is told a page liked their post, named as the page" do
    {page, owner} = page_with_publisher()
    {post, author} = a_post()

    assert :ok = Posts.like_post(page, owner, post)

    %{entries: [entry]} = Vutuv.Activity.notifications_page(author.id)
    assert entry.kind == "like"
    # The page is the actor a reader sees; the publisher who pressed it is not
    # named in the notification at all.
    assert entry.actor_name == page.name
  end
end
