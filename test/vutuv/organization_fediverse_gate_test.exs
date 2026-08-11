defmodule Vutuv.OrganizationFediverseGateTest do
  @moduledoc """
  Whether a page federates (issue #1334) — the gate every other piece of that
  half hangs off.

  It ships **off**, and that is what lets the rest land one piece at a time:
  WebFinger, the actor document, the collections, the inbox and delivery are all
  refused for a page that has not opted in, so none of them is visible to
  another server before the chain is complete. A page that never switches it on
  behaves exactly as it does today.

  The predicate mirrors the member one (`enabled?` AND opted in AND the account
  is in good standing) with the page's own notion of standing: active and not
  frozen, which is `Organizations.public_visible?/1`. A page nobody may open
  must not be answering for itself on another network either.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Repo

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  # Opting in AND claiming a handle: the handle is the page's address out there,
  # so both are required before it federates.
  defp opted_in(organization, handle \\ "acme") do
    organization
    |> Ecto.Changeset.change(%{fediverse_followers?: true, username: handle})
    |> Repo.update!()
  end

  test "a page does not federate until somebody says so" do
    organization = active_organization_for(insert(:activated_user))

    refute organization.fediverse_followers?
    refute Fediverse.federated?(organization)
  end

  test "an opted-in active page federates" do
    organization = active_organization_for(insert(:activated_user)) |> opted_in()

    assert Fediverse.federated?(organization)
  end

  test "an opted-in page without a handle does not federate" do
    organization =
      active_organization_for(insert(:activated_user))
      |> Ecto.Changeset.change(%{fediverse_followers?: true})
      |> Repo.update!()

    # WebFinger's `subject` and the actor document's `preferredUsername` are
    # both built from the handle, so opting in without one would not federate
    # the page — it would publish an actor nobody can address.
    assert is_nil(organization.username)
    refute Fediverse.federated?(organization)
  end

  test "a frozen page does not, however it is flagged" do
    organization = active_organization_for(insert(:activated_user)) |> opted_in()
    {:ok, frozen} = Organizations.admin_set_frozen(organization, true)

    # `status` stays "active" through a freeze, so a gate reading only that
    # would keep answering for a page the site itself hides.
    refute Fediverse.federated?(frozen)
  end

  test "a pending page does not" do
    owner = insert(:activated_user)

    {:ok, %{organization: pending}} =
      Organizations.create_pending_organization(owner, valid_organization_attrs(), "dns")

    pending = opted_in(pending)

    refute Fediverse.federated?(pending)
  end

  test "ever_federated? asks whether a keypair was ever minted, not the switch" do
    organization = active_organization_for(insert(:activated_user)) |> opted_in()

    # The distinction matters for takedowns: turning the switch off does not
    # unsend what other servers already hold, so anything that has to reach them
    # afterwards keys on the keypair having existed, not on the current flag.
    refute Fediverse.ever_federated?(organization)

    {:ok, _} = Fediverse.ensure_organization_actor(organization)
    assert Fediverse.ever_federated?(organization)

    switched_off =
      Ecto.Changeset.change(organization, %{fediverse_followers?: false}) |> Repo.update!()

    refute Fediverse.federated?(switched_off)
    assert Fediverse.ever_federated?(switched_off)
  end

  test "the whole installation switch still wins" do
    organization = active_organization_for(insert(:activated_user)) |> opted_in()

    original = Application.fetch_env(:vutuv, :fediverse_enabled)
    Application.put_env(:vutuv, :fediverse_enabled, false)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :fediverse_enabled, was)
        :error -> Application.delete_env(:vutuv, :fediverse_enabled)
      end
    end)

    refute Fediverse.federated?(organization)
    assert %Organization{} = organization
  end
end
