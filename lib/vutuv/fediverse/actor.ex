defmodule Vutuv.Fediverse.Actor do
  @moduledoc """
  A member's Fediverse actor: the RSA keypair behind their ActivityPub
  identity, created lazily when they opt in (`users.fediverse_followers?`).
  The private key signs outbound deliveries; the public key is published in
  the actor document.
  """

  use VutuvWeb, :model

  schema "fediverse_actors" do
    field(:private_key_pem, :string)
    field(:public_key_pem, :string)

    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end
end
