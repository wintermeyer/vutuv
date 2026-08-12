defmodule Vutuv.Fediverse.Actor do
  @moduledoc """
  A Fediverse actor: the RSA keypair behind an ActivityPub identity, created
  lazily on opt-in. The private key signs outbound deliveries; the public key
  is published in the actor document.

  The owner is a **member, an organization page (issue #1334) or a tag (issue
  #1330)**, CHECK-enforced to exactly one. The page and tag halves are the
  foundation of their issues' fediverse work: a keypair is invisible outside
  this database, so it can ship on its own, while the parts other servers can
  see (WebFinger, the actor document, delivery, the inbox) have to land
  together — being findable without an inbox that answers Follow is worse than
  not being findable.

  A tag's actor name is its slug with no mapping in between, which is why this
  had to wait for the slug grammar to be settled (#1337/#1332): renaming an
  actor other servers already follow costs a `Move` per tag.
  """

  use VutuvWeb, :model

  schema "fediverse_actors" do
    field(:private_key_pem, :string)
    field(:public_key_pem, :string)

    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:organization, Vutuv.Organizations.Organization)
    belongs_to(:tag, Vutuv.Tags.Tag)

    timestamps()
  end
end
