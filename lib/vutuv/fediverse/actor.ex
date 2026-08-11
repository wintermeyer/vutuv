defmodule Vutuv.Fediverse.Actor do
  @moduledoc """
  A Fediverse actor: the RSA keypair behind an ActivityPub identity, created
  lazily on opt-in. The private key signs outbound deliveries; the public key
  is published in the actor document.

  The owner is a **member or an organization page** (issue #1334),
  CHECK-enforced to exactly one. The page half is the foundation of that
  issue's fediverse work and has no writer yet: a keypair is invisible outside
  this database, so it could ship on its own, while the parts other servers can
  see (WebFinger, the actor document, delivery, the inbox) have to land
  together — being findable without an inbox that answers Follow is worse than
  not being findable.
  """

  use VutuvWeb, :model

  schema "fediverse_actors" do
    field(:private_key_pem, :string)
    field(:public_key_pem, :string)

    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:organization, Vutuv.Organizations.Organization)

    timestamps()
  end
end
