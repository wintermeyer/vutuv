defmodule Vutuv.OrganizationFollowGapsTest do
  @moduledoc """
  Following a page is following, and two surfaces disagreed.

  `follows_anyone?/1` reaches the followee through an INNER JOIN to `users`, and
  an organization follow has `followee_id IS NULL` — the second of the three
  shapes the nullable-pair model keeps producing, and the one that fails
  silently. `toggle_follow_mute!/2` went through a changeset that re-validates
  `followee_id`, which fails loudly instead.

  Still open, and deliberately not asserted here: the Following **list** and its
  count omit followed pages the same way, so a member cannot see or unfollow a
  page except by returning to it. That one is not a query fix — a page has a
  logo and no work history or tags, so it needs its own section rather than a
  row in `card_list`, plus the agent-format siblings and the API.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
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

  defp page_with_a_post do
    owner = insert(:activated_user)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Neu bei uns."})
    {organization, post}
  end

  test "a member who follows only pages is sent to their feed, not their profile" do
    {organization, _post} = page_with_a_post()
    member = insert(:activated_user)
    {:ok, _} = Social.follow_organization(member, organization)

    # Their feed really does have something in it — the page's post arrives
    # through feed_organization_post_items/3. Sending them to their own profile
    # instead is the app telling them they follow nobody while showing them
    # posts from somebody.
    assert %{entries: [_ | _]} = Posts.feed_page(member)
    assert Social.follows_anyone?(member)
  end

  test "muting a page's follow works instead of raising" do
    {organization, _post} = page_with_a_post()
    member = insert(:activated_user)
    {:ok, follow} = Social.follow_organization(member, organization)

    # PUT /follows/:id/mute is reachable with any follow id the member owns, so
    # a changeset that still demands followee_id turns it into a 500.
    muted = Social.toggle_follow_mute!(member.id, follow.id)
    assert muted.muted
  end
end
