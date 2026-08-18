defmodule Vutuv.OrganizationFediverseFollowersTest do
  @moduledoc """
  A remote account can follow a **page** (issue #1334) — the landing place the
  page's inbox needs. Without it the inbox has nowhere to put what it accepts.

  Fifth table to take the nullable pair. The second unique index is not tidiness
  here: `add_follower/2` upserts on `[:user_id, :actor_uri]`, so the page twin
  needs its own conflict target to stay idempotent, and a repeat Follow from the
  same server is the normal case rather than the exception.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follower
  alias Vutuv.Repo

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp page, do: active_organization_for(insert(:activated_user))

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        actor_uri: "https://remote.example/users/frida",
        inbox_uri: "https://remote.example/users/frida/inbox",
        handle: "@frida@remote.example",
        name: "Frida"
      },
      overrides
    )
  end

  test "the database refuses a row naming both targets or neither" do
    organization = page()
    member = insert(:activated_user)

    assert_raise Ecto.ConstraintError, ~r/fediverse_followers_exactly_one_target/, fn ->
      Repo.insert!(%Follower{
        user_id: member.id,
        organization_id: organization.id,
        actor_uri: "https://remote.example/users/a",
        inbox_uri: "https://remote.example/users/a/inbox"
      })
    end

    assert_raise Ecto.ConstraintError, ~r/fediverse_followers_exactly_one_target/, fn ->
      Repo.insert!(%Follower{
        actor_uri: "https://remote.example/users/b",
        inbox_uri: "https://remote.example/users/b/inbox"
      })
    end
  end

  test "a remote account follows a page, and a repeat Follow re-syncs rather than duplicates" do
    organization = page()

    assert {:ok, follower} = Fediverse.add_organization_follower(organization, attrs())
    assert follower.organization_id == organization.id
    assert is_nil(follower.user_id)

    # The rename case the member side already handles: a second Follow carries
    # fresh display fields and must update the row, not mint a second one.
    assert {:ok, again} =
             Fediverse.add_organization_follower(organization, attrs(%{name: "Frida F."}))

    assert Fediverse.follower_count(organization) == 1
    assert again.name == "Frida F."

    # The returned struct must BE the stored row. With client-generated UUIDs an
    # upsert otherwise hands back the id Ecto minted for the INSERT that lost —
    # an id no row ever had — which is only invisible while nobody uses it.
    assert again.id == follower.id
  end

  test "the same remote account may follow a member and a page independently" do
    organization = page()
    member = insert(:activated_user)

    {:ok, _} = Fediverse.add_follower(member, attrs())
    {:ok, _} = Fediverse.add_organization_follower(organization, attrs())

    # Two different relationships, so two rows — and neither unique index may
    # mistake one for the other.
    assert Fediverse.follower_count(member) == 1
    assert Fediverse.follower_count(organization) == 1
  end

  test "an Undo drops only that page's row" do
    organization = page()
    member = insert(:activated_user)

    {:ok, _} = Fediverse.add_follower(member, attrs())
    {:ok, _} = Fediverse.add_organization_follower(organization, attrs())

    assert Fediverse.remove_organization_follower(organization, attrs().actor_uri) == 1

    assert Fediverse.follower_count(organization) == 0
    assert Fediverse.follower_count(member) == 1

    # Idempotent: an Undo for a follow that is already gone is a no-op.
    assert Fediverse.remove_organization_follower(organization, attrs().actor_uri) == 0
  end

  test "the member readers cannot see a page's followers" do
    organization = page()
    member = insert(:activated_user)

    {:ok, _} = Fediverse.add_organization_follower(organization, attrs())

    assert Fediverse.follower_count(member) == 0
    assert Fediverse.list_followers(member) == []
    assert [%Follower{}] = Fediverse.list_organization_followers(organization)
  end

  test "deleting the page takes its remote followers with it" do
    organization = page()
    {:ok, _} = Fediverse.add_organization_follower(organization, attrs())

    {:ok, _} = Vutuv.Organizations.delete_organization(organization)

    assert Fediverse.follower_count(organization) == 0
  end

  describe "browsing them" do
    setup do
      organization = page()
      member = insert(:activated_user)

      # One follower of a MEMBER on the same server, to prove the scoping: the
      # browser reads one shared table where a page's rows hang off
      # `organization_id` and a member's off `user_id`.
      {:ok, _} = Fediverse.add_follower(member, attrs())

      {:ok, _} =
        Fediverse.add_organization_follower(
          organization,
          attrs(%{
            actor_uri: "https://remote.example/users/hans",
            handle: "@hans@remote.example",
            name: "Hans"
          })
        )

      {:ok, _} =
        Fediverse.add_organization_follower(
          organization,
          attrs(%{
            actor_uri: "https://andere.example/users/ida",
            inbox_uri: "https://andere.example/users/ida/inbox",
            handle: "@ida@andere.example",
            name: "Ida"
          })
        )

      {:ok, organization: organization, member: member}
    end

    test "the page's own rows, and nobody else's", %{organization: organization, member: member} do
      filters = Fediverse.browse_filters(%{})

      assert Fediverse.count_followers(organization, filters) == 2
      assert Fediverse.count_followers(member, filters) == 1

      names =
        organization
        |> Fediverse.list_followers_page(filters)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["Hans", "Ida"]
    end

    test "searching and filtering by server work on a page too", %{organization: organization} do
      assert [%Follower{name: "Ida"}] =
               Fediverse.list_followers_page(
                 organization,
                 Fediverse.browse_filters(%{"q" => "ida"})
               )

      assert [%Follower{name: "Hans"}] =
               Fediverse.list_followers_page(
                 organization,
                 Fediverse.browse_filters(%{"server" => "remote.example"})
               )
    end

    test "the server list counts only the page's followers", %{organization: organization} do
      hosts = Fediverse.follower_hosts(organization)

      assert Enum.sort_by(hosts, & &1.host) == [
               %{host: "andere.example", count: 1},
               %{host: "remote.example", count: 1}
             ]
    end
  end
end
