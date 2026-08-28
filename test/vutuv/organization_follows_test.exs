defmodule Vutuv.OrganizationFollowsTest do
  @moduledoc """
  Members following an organization (issue #1336, first table): the follow edge
  itself, and the thing it exists for — the page's posts reaching the follower's
  feed.

  It also pins down the NULL trap the nullable-pair model creates. The member id
  lists behind the feed's sources feed `IN` and, worse, `NOT IN` subqueries, and
  `x NOT IN (…, NULL)` is **never true** in SQL — so a single organization follow
  leaking a NULL into one of those lists would silently empty a whole source.
  Two tests here exist only to catch that.

  `async: false` because the helpers flip the global
  `:verify_organization_domains` flag.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers
  import Vutuv.PostsHelpers, only: [backdate_post!: 2]

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Social.Follow
  alias Vutuv.Social.PastFollow

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

  defp ago(seconds), do: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -seconds)

  # Moves the span an unfollow just recorded (issue #1673) into the past, so a
  # test can place posts inside and after it.
  defp backdate_span!(member, organization, started_ago, ended_ago) do
    {1, nil} =
      Repo.update_all(
        from(w in PastFollow,
          where: w.follower_id == ^member.id and w.followee_organization_id == ^organization.id
        ),
        set: [started_at: ago(started_ago), ended_at: ago(ended_ago)]
      )

    :ok
  end

  describe "the follow edge" do
    test "follows, is idempotent, and unfollows" do
      {organization, _owner} = publishing_organization()
      member = insert(:activated_user)

      refute Social.follows_organization?(member, organization)

      assert {:ok, follow} = Social.follow_organization(member, organization)
      assert Social.follows_organization?(member, organization)
      assert Social.organization_follower_count(organization) == 1

      # A double click is not a failure.
      assert {:ok, same} = Social.follow_organization(member, organization)
      assert same.id == follow.id
      assert Social.organization_follower_count(organization) == 1

      assert :ok = Social.unfollow_organization(member, organization)
      refute Social.follows_organization?(member, organization)
      # …and unfollowing twice is not one either.
      assert :ok = Social.unfollow_organization(member, organization)
    end

    test "the database refuses an edge naming both kinds of followee or neither" do
      {organization, owner} = publishing_organization()
      member = insert(:activated_user)

      assert_raise Ecto.ConstraintError, ~r/follows_exactly_one_followee/, fn ->
        Repo.insert!(%Follow{
          follower_id: member.id,
          followee_id: owner.id,
          followee_organization_id: organization.id
        })
      end

      assert_raise Ecto.ConstraintError, ~r/follows_exactly_one_followee/, fn ->
        Repo.insert!(%Follow{follower_id: member.id})
      end
    end
  end

  describe "the feed" do
    test "carries the posts of a followed organization, and stops at the unfollow" do
      {organization, owner} = publishing_organization()
      member = insert(:activated_user)

      {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Neuigkeit."})
      # The whole test runs inside one second and every timestamp here has
      # second precision, so the follow's span would be a point rather than a
      # range and the assertions below would decide a tie instead of a rule.
      # Hence the two explicit shifts into the past.
      post = backdate_post!(post, 30)

      # Not following: not in the feed.
      refute post.id in feed_post_ids(member)

      {:ok, _} = Social.follow_organization(member, organization)
      assert post.id in feed_post_ids(member)

      :ok = Social.unfollow_organization(member, organization)
      backdate_span!(member, organization, 60, 1)

      # Since issue #1673 an unfollow stops the future instead of erasing the
      # past: this post arrived while the follow stood, so it stays.
      assert post.id in feed_post_ids(member)

      {:ok, later} = Posts.create_organization_post(organization, owner, %{body: "Danach."})
      refute later.id in feed_post_ids(member)
    end

    test "a frozen page's posts leave the feed" do
      {organization, owner} = publishing_organization()
      member = insert(:activated_user)
      {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Vorher."})
      {:ok, _} = Social.follow_organization(member, organization)

      assert post.id in feed_post_ids(member)

      {:ok, _} = Organizations.admin_set_frozen(organization, true)
      refute post.id in feed_post_ids(member)
    end

    test "following an organization does not disturb the member half of the feed" do
      {organization, owner} = publishing_organization()
      member = insert(:activated_user)
      friend = insert(:activated_user)

      {:ok, _} = Social.follow(member, friend.id)
      {:ok, friend_post} = Posts.create_post(friend, %{body: "Von einem Menschen."})
      {:ok, _} = Social.follow_organization(member, organization)
      {:ok, org_post} = Posts.create_organization_post(organization, owner, %{body: "Von uns."})

      ids = feed_post_ids(member)
      assert friend_post.id in ids
      assert org_post.id in ids
    end
  end

  describe "the SQL NULL trap the nullable pair creates" do
    # `all_followees_of/1` is the list that carries the trap, and the feed's
    # **tag source** is what asks it: a post carrying a tag you follow reaches
    # you only when its author is somebody you do not already follow. The probe
    # used to be the feed's suggestion rail, which is gone.
    test "a followed tag still finds strangers once an organization is followed" do
      {organization, _owner} = publishing_organization()
      member = insert(:activated_user)
      stranger = insert(:activated_user)

      name = Vutuv.Factory.unique_tag_name("Elixir")
      tag = insert(:tag, name: name, slug: Vutuv.SlugHelpers.tagify(name))
      Vutuv.Tags.follow_tag(member, tag)

      {:ok, post} = Posts.create_post(stranger, %{body: "Hallo Welt.", tags: name})

      assert post.id in feed_post_ids(member)

      {:ok, _} = Social.follow_organization(member, organization)

      # `p.user_id NOT IN (…, NULL)` is never true, so an organization follow
      # leaking a NULL into the "people I already follow" list would empty this
      # source completely — silently, and for every reader who follows a page.
      assert post.id in feed_post_ids(member)
    end

    test "the member following-count includes organizations" do
      {organization, _owner} = publishing_organization()
      member = insert(:activated_user)
      friend = insert(:activated_user)

      {:ok, _} = Social.follow(member, friend.id)
      {:ok, _} = Social.follow_organization(member, organization)

      # This reverses the earlier decision that "Following" on a profile means
      # people and a page is counted on the page instead. The Following list now
      # has an Organizations section, and the two have to agree: a member who
      # follows only pages would otherwise read "Following 0" above a link to a
      # page that lists them. A total of both is not a contradiction — the list
      # underneath splits it and counts each section.
      assert Social.followee_count(member) == 2
      assert Social.followed_organization_count(member) == 1
    end
  end

  defp feed_post_ids(member) do
    member
    |> Posts.feed_page()
    |> Map.fetch!(:entries)
    |> Enum.map(& &1.post.id)
  end
end
