defmodule Vutuv.Credentials.UserCredential do
  @moduledoc """
  One enrolled passkey / WebAuthn (FIDO2) credential of a `Vutuv.Accounts.User`
  (issue #795).

  A passkey is a public-key credential bound to the origin (`vutuv.de`): the
  private key never leaves the member's device, only the `public_key` (the COSE
  key Wax verified at registration) and the `credential_id` handle are stored
  here. Signing in proves possession of the private key, the same shape as the
  `Vutuv.Sessions.UserSession` token but driven by the authenticator, not a
  cookie. `sign_count` is the authenticator's signature counter, used to detect
  a cloned credential; `aaguid` is the authenticator model id, kept for future
  labelling.

  All of `credential_id`, `public_key`, `sign_count`, `aaguid` and `user_id` are
  set programmatically from the verified attestation in `Vutuv.Credentials` —
  never cast from request params. The only member-supplied field is the
  `nickname` shown in the passkey list.
  """

  use VutuvWeb, :model

  schema "user_credentials" do
    belongs_to(:user, Vutuv.Accounts.User)

    field(:credential_id, :binary)
    field(:public_key, :binary)
    field(:sign_count, :integer, default: 0)
    field(:aaguid, :binary)
    field(:nickname, :string)
    field(:last_used_at, :utc_datetime)

    timestamps()
  end

  @doc false
  # Only the nickname is member-supplied; the keypair handle, public key, counter
  # and owner are set programmatically by Vutuv.Credentials from the verified
  # WebAuthn attestation, so there is nothing else to cast.
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:nickname])
    |> validate_length(:nickname, max: 100)
  end
end
