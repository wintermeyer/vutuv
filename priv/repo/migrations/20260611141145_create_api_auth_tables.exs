defmodule Vutuv.Repo.Migrations.CreateApiAuthTables do
  use Ecto.Migration

  def change do
    # The third-party API's credential store (Vutuv.ApiAuth). Four tables,
    # purely additive, N-1 safe. Secrets are never stored in the clear: every
    # token / client secret / auth code column holds a SHA-256 hash.

    # A registered third-party application (OAuth client). `client_id` is the
    # public identifier; `client_secret_hash` is null for public clients
    # (PKCE-only, e.g. mobile/SPA).
    create table(:oauth_apps) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:homepage_url, :string)
      add(:redirect_uris, {:array, :string}, null: false, default: [])
      add(:client_id, :string, null: false)
      add(:client_secret_hash, :string)
      add(:suspended_at, :utc_datetime)

      timestamps()
    end

    create(unique_index(:oauth_apps, [:client_id]))
    create(index(:oauth_apps, [:user_id]))

    # One row per user × app: which scopes the user granted. Revoking sets
    # `revoked_at` (and kills the grant's tokens); re-authorizing reuses the
    # row. This is what the "Connected apps" settings page lists.
    create table(:oauth_grants) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:app_id, references(:oauth_apps, on_delete: :delete_all), null: false)
      add(:scopes, {:array, :string}, null: false, default: [])
      add(:revoked_at, :utc_datetime)

      timestamps()
    end

    create(unique_index(:oauth_grants, [:user_id, :app_id]))
    create(index(:oauth_grants, [:app_id]))

    # Short-lived one-time codes for the authorization-code flow, with the
    # PKCE challenge. `used_at` marks consumption; a second use is the RFC's
    # token-theft signal and revokes the grant's tokens.
    create table(:oauth_auth_codes) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:app_id, references(:oauth_apps, on_delete: :delete_all), null: false)
      add(:grant_id, references(:oauth_grants, on_delete: :delete_all))
      add(:code_hash, :string, null: false)
      add(:redirect_uri, :string, null: false)
      add(:scopes, {:array, :string}, null: false, default: [])
      add(:code_challenge, :string, null: false)
      add(:code_challenge_method, :string, null: false, default: "S256")
      add(:expires_at, :utc_datetime, null: false)
      add(:used_at, :utc_datetime)

      timestamps(updated_at: false)
    end

    create(unique_index(:oauth_auth_codes, [:code_hash]))
    create(index(:oauth_auth_codes, [:user_id]))
    create(index(:oauth_auth_codes, [:app_id]))

    # Every bearer credential: personal access tokens (kind "pat", app_id
    # null) and the OAuth access/refresh pairs (kind "access"/"refresh",
    # tied to a grant). Lookup is by hash; `last_used_at` is the audit trail.
    create table(:api_tokens) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:app_id, references(:oauth_apps, on_delete: :delete_all))
      add(:grant_id, references(:oauth_grants, on_delete: :delete_all))
      add(:kind, :string, null: false)
      add(:token_hash, :string, null: false)
      add(:name, :string)
      add(:scopes, {:array, :string}, null: false, default: [])
      add(:expires_at, :utc_datetime)
      add(:last_used_at, :utc_datetime)
      add(:revoked_at, :utc_datetime)

      timestamps()
    end

    create(unique_index(:api_tokens, [:token_hash]))
    create(index(:api_tokens, [:user_id]))
    create(index(:api_tokens, [:grant_id]))
    create(index(:api_tokens, [:app_id]))
  end
end
