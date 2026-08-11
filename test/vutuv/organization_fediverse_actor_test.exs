defmodule Vutuv.OrganizationFediverseActorTest do
  @moduledoc """
  A page can hold a Fediverse keypair (issue #1334) — the foundation of that
  issue's fediverse half, and the only part of it that can ship alone.

  Everything else in that half is visible to other servers, and those parts have
  to arrive together: WebFinger that resolves a page handle, an `Organization`
  actor document, delivery signed as the page, and an inbox that answers Follow.
  Being findable without a working inbox means somebody on Mastodon presses
  Follow and nothing ever happens, which is worse than not being findable at
  all. A keypair has no such edge — nothing outside this database can see one.

  So these tests do what the two earlier expand steps did: prove the column and
  its constraint, and prove the existing member readers cannot be confused by
  the new row shape.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Actor
  alias Vutuv.Repo

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  test "the database refuses an actor with both owners or neither" do
    member = insert(:activated_user)
    organization = active_organization_for(insert(:activated_user))

    assert_raise Ecto.ConstraintError, ~r/fediverse_actors_exactly_one_owner/, fn ->
      Repo.insert!(%Actor{
        user_id: member.id,
        organization_id: organization.id,
        private_key_pem: "x",
        public_key_pem: "y"
      })
    end

    assert_raise Ecto.ConstraintError, ~r/fediverse_actors_exactly_one_owner/, fn ->
      Repo.insert!(%Actor{private_key_pem: "x", public_key_pem: "y"})
    end
  end

  test "a page gets one keypair, and asking twice returns the same one" do
    organization = active_organization_for(insert(:activated_user))

    assert {:ok, actor} = Fediverse.ensure_organization_actor(organization)
    assert actor.organization_id == organization.id
    assert is_nil(actor.user_id)
    assert actor.private_key_pem =~ "PRIVATE KEY"
    assert actor.public_key_pem =~ "PUBLIC KEY"

    assert {:ok, same} = Fediverse.ensure_organization_actor(organization)
    assert same.id == actor.id
  end

  test "a page's actor is invisible to the member lookups, and the other way round" do
    member = insert(:activated_user)
    organization = active_organization_for(insert(:activated_user))

    {:ok, _} = Fediverse.ensure_organization_actor(organization)

    # `get_actor/1` reads `user_id`, which a page row leaves NULL — so the two
    # namespaces cannot bleed into each other even though they share a table.
    refute Fediverse.get_actor(member)

    {:ok, member_actor} = Fediverse.ensure_actor(member)
    assert Fediverse.get_actor(member).id == member_actor.id
    assert Fediverse.get_organization_actor(organization).organization_id == organization.id
    refute Fediverse.get_organization_actor(organization).id == member_actor.id
  end

  test "deleting the page takes its keypair with it" do
    organization = active_organization_for(insert(:activated_user))
    {:ok, _} = Fediverse.ensure_organization_actor(organization)

    {:ok, _} = Vutuv.Organizations.delete_organization(organization)

    refute Fediverse.get_organization_actor(organization)
  end
end
