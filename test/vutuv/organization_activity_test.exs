defmodule Vutuv.OrganizationActivityTest do
  @moduledoc """
  A page's own activity and its **shared** read marker (issue #1336).

  The read state is the part the issue calls subtle, and the tests below are
  what pin the chosen model down: one marker on the page, so "read" means
  somebody on the team read it and never that everybody did. Storing it as a
  column rather than a row per member is the decision, so a test that only
  checked counts would not have caught the wrong shape.

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

  defp publishing_organization do
    {organization, owner} = active_organization()
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {organization, owner}
  end

  test "collects follows, likes and reposts of the page, newest first" do
    {organization, owner} = publishing_organization()
    {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Unser Beitrag."})

    follower = insert(:activated_user)
    liker = insert(:activated_user)
    reposter = insert(:activated_user)

    {:ok, _} = Social.follow_organization(follower, organization)
    :ok = Posts.like_post(liker, post)
    :ok = Posts.repost_post(reposter, post)

    %{entries: entries} = Organizations.activity_page(organization)
    kinds = Enum.map(entries, & &1.kind)

    assert "follow" in kinds
    assert "post_like" in kinds
    assert "post_repost" in kinds

    # A like and a repost carry the post they are about; a follow does not.
    like = Enum.find(entries, &(&1.kind == "post_like"))
    assert like.post.id == post.id
    assert like.actor.id == liker.id
    assert Enum.find(entries, &(&1.kind == "follow")).post == nil
  end

  # A page likes and reposts too (issue #1336), and its row carries
  # `organization_id` with `user_id` NULL. The join to `users` was an inner one,
  # so such a row never reached the list at all: the team was simply never told
  # another page had engaged with their post, and nothing anywhere logged it.
  # Same shape `Activity.like_items/3` fixed with LEFT joins on both actor sides.
  # Calibrated against the un-fixed code, where both assertions below fail.
  test "a page's like and repost reach the activity list, named as the page" do
    {organization, owner} = publishing_organization()
    {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Unser Beitrag."})

    other_owner = insert(:activated_user)

    other =
      active_organization_for(other_owner, %{
        "name" => "Zweite AG",
        "website_url" => "https://zweite.example"
      })

    {:ok, _} = Organizations.add_role(other, other_owner, "publisher", other_owner)

    :ok = Posts.like_post(other, other_owner, post)
    :ok = Posts.repost_post(other, other_owner, post)

    %{entries: entries} = Organizations.activity_page(organization)

    like = Enum.find(entries, &(&1.kind == "post_like"))
    repost = Enum.find(entries, &(&1.kind == "post_repost"))

    assert like, "a page's like never reached the list"
    assert repost, "a page's repost never reached the list"

    assert like.actor.id == other.id
    assert repost.actor.id == other.id

    # The badge reads the same query, so one fix covers both — but a team that
    # is never told is exactly what the missing rows looked like.
    assert Organizations.unread_activity_count(organization) >= 2
  end

  test "a post naming the page by its handle reaches its activity, and an edit undoes it" do
    {organization, owner} = active_organization()
    {:ok, organization} = Organizations.claim_handle(organization, %{"username" => "genanntag"})
    author = insert(:activated_user)

    {:ok, post} = Posts.create_post(author, %{body: "Schönes Ding von @genanntag."})

    assert [%{kind: "mention", actor: actor, post: mentioned}] =
             Organizations.activity_page(organization).entries

    assert actor.id == author.id
    assert mentioned.id == post.id
    # The link the page's team clicks needs the post's own author preloaded.
    assert Posts.path(mentioned) =~ author.username

    # Editing the mention out takes the entry with it — the rows are a
    # reconciled index of the body, never a log of what was once written.
    {:ok, _} = Posts.update_post(post, %{body: "Schönes Ding."})
    assert Organizations.activity_page(organization).entries == []

    # The owner is untouched by all of this; it is the page that was named.
    assert owner.id != author.id
  end

  test "the page naming itself is not news to its own team" do
    {organization, owner} = active_organization()
    {:ok, organization} = Organizations.claim_handle(organization, %{"username" => "selbstag"})
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

    {:ok, _} =
      Posts.create_organization_post(organization, owner, %{body: "Wir bei @selbstag freuen uns."})

    # Its own post is already on the page above; a mention of itself inside it
    # would be the same news twice.
    assert Organizations.activity_page(organization).entries == []
  end

  test "an event disappears with the row behind it" do
    {organization, owner} = publishing_organization()
    {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Kurz."})
    liker = insert(:activated_user)

    :ok = Posts.like_post(liker, post)
    assert Organizations.activity_page(organization).entries != []

    # Derived from the source tables rather than written twice, so unliking is
    # not "read" — it never happened.
    :ok = Posts.unlike_post(liker, post)
    assert Organizations.activity_page(organization).entries == []
  end

  test "another page's activity never appears" do
    {mine, _owner} = publishing_organization()

    {theirs, their_owner} =
      active_organization(%{"name" => "Fremd AG", "website_url" => "https://fremd.example"})

    {:ok, _} = Organizations.add_role(theirs, their_owner, "publisher", their_owner)
    {:ok, their_post} = Posts.create_organization_post(theirs, their_owner, %{body: "Ihres."})
    :ok = Posts.like_post(insert(:activated_user), their_post)
    {:ok, _} = Social.follow_organization(insert(:activated_user), theirs)

    assert Organizations.activity_page(mine).entries == []
  end

  describe "the shared read marker" do
    test "one member opening the list clears it for the whole team" do
      {organization, owner} = publishing_organization()
      other = insert(:activated_user)
      {:ok, _} = Organizations.add_role(organization, other, "admin", owner)
      {:ok, _} = Social.follow_organization(insert(:activated_user), organization)

      # Nobody has looked yet: a nil marker means everything is new.
      assert is_nil(organization.activity_read_at)
      assert Organizations.unread_activity_count(organization) == 1

      # One of them opens it …
      {:ok, organization} = Organizations.mark_activity_read(organization)

      # … and it is read for all of them. There is no per-member state to
      # disagree with this, which is the whole design.
      assert organization.activity_read_at
      assert Organizations.unread_activity_count(organization) == 0
    end

    test "something that happens after the marker counts as unread again" do
      {organization, _owner} = publishing_organization()
      {:ok, organization} = Organizations.mark_activity_read(organization)
      assert Organizations.unread_activity_count(organization) == 0

      {:ok, _} = Social.follow_organization(insert(:activated_user), organization)

      assert Organizations.unread_activity_count(Repo.reload!(organization)) == 1
    end
  end
end
