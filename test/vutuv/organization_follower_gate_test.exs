defmodule Vutuv.OrganizationFollowerGateTest do
  @moduledoc """
  Two leftovers from the nullable-pair milestone, both about a gate that one
  side of a pair applies and the other does not.

  A page's follower **count** gated on nothing while the follower list on its
  activity page gated on confirmed-and-not-hidden, so the number above the page
  could exceed everyone it would ever name. The member side has kept those two
  in step from the start — `follower_count_query/1` carries a comment saying it
  matches `Follow.latest/2` — and the organization twin was written without it.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
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

  defp activity_follower_ids(organization) do
    organization
    |> Organizations.activity_page()
    |> Map.fetch!(:entries)
    |> Enum.filter(&(&1.kind == "follow"))
    |> Enum.map(& &1.actor.id)
  end

  test "an unconfirmed follower is left out of the count, as it is out of the list" do
    owner = insert(:activated_user)
    organization = active_organization_for(owner)

    shown = insert(:activated_user)
    hidden = insert(:user, email_confirmed?: false)

    {:ok, _} = Social.follow_organization(shown, organization)
    {:ok, _} = Social.follow_organization(hidden, organization)

    assert activity_follower_ids(organization) == [shown.id]
    assert Social.organization_follower_count(organization) == 1
  end

  test "a page following a page is not counted as one of its members" do
    owner = insert(:activated_user)
    organization = active_organization_for(owner)

    other =
      active_organization_for(insert(:activated_user), %{
        "name" => "Zweite AG",
        "website_url" => "https://zweite.example"
      })

    member = insert(:activated_user)
    {:ok, _} = Social.follow_organization(member, organization)

    Repo.insert!(%Follow{
      follower_organization_id: other.id,
      followee_organization_id: organization.id
    })

    # The activity list joins `users` on the follower, so it can never show a
    # page; a count that includes one would promise a follower nobody can see.
    # (Whether a page's followers should list pages at all is the writer's
    # decision — see the plan on issue #1336. Until then the two agree.)
    assert activity_follower_ids(organization) == [member.id]
    assert Social.organization_follower_count(organization) == 1
  end
end
