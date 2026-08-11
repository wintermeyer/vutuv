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
