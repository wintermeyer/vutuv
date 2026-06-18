defmodule Vutuv.Repo.Migrations.CreateUserCredentials do
  use Ecto.Migration

  def change do
    # One row per enrolled passkey / WebAuthn (FIDO2) credential, so a member
    # can sign in with Touch ID / Windows Hello / a security key instead of
    # waiting for an emailed PIN (issue #795). See Vutuv.Credentials.
    #
    # Purely additive and N-1 backward compatible: the currently-deployed
    # release ignores the table; the email-PIN login is untouched and stays the
    # only way to bootstrap an account, so a passkey is never the root of trust.
    #
    # credential_id and public_key are the WebAuthn keypair handle and its COSE
    # public key (set programmatically from the verified attestation, never cast
    # from user input). The private key never leaves the member's device.
    create table(:user_credentials) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      # The raw credential id bytes (the browser's rawId). Globally unique.
      add(:credential_id, :binary, null: false)
      # The COSE public key, :erlang.term_to_binary/1 of the map Wax returns.
      add(:public_key, :binary, null: false)
      # The authenticator's signature counter, for clone detection.
      add(:sign_count, :integer, null: false, default: 0)
      # The authenticator model id (16 bytes), kept for future labelling.
      add(:aaguid, :binary)
      # The member-given name ("MacBook", "YubiKey") shown in the device list.
      add(:nickname, :string)
      add(:last_used_at, :utc_datetime)

      timestamps()
    end

    create(unique_index(:user_credentials, [:credential_id]))
    create(index(:user_credentials, [:user_id]))
  end
end
