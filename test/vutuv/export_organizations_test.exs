defmodule Vutuv.ExportOrganizationsTest do
  @moduledoc """
  The pages on either side of a follow, in the personal data export (issue
  #1336, schema v9). An export that answers "who follows me" has to name them:
  leaving them out was the actual problem, and `followers` / `following` cannot
  simply take them, because those entries carry a `username` a page need never
  have claimed.

  Its own file rather than a case in `export_test.exs`: that module is
  `async: true`, and the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Export
  alias Vutuv.Social

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  test "both directions of a page follow are named" do
    member = insert(:activated_user)

    followed = active_organization_for(insert(:activated_user))

    follower =
      active_organization_for(insert(:activated_user), %{
        "name" => "Zweite AG",
        "website_url" => "https://zweite.example"
      })

    {:ok, _} = Social.follow_organization(member, followed)
    {:ok, _} = Social.follow_as_organization(follower, member)

    data = Export.build(member)

    assert data.schema_version >= 9
    assert [%{name: "Acme GmbH", slug: _, since: _}] = data.following_organizations
    assert [%{name: "Zweite AG"}] = data.follower_organizations

    # The member lists stay members: a page has no username to put there.
    assert data.followers == []
    assert data.following == []
  end
end
