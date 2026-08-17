defmodule Vutuv.Repo.Migrations.CreateOauthAppTokens do
  use Ecto.Migration

  # An app token is a credential with **no member behind it**: RFC 6749's
  # `client_credentials` grant, which Mastodon's token endpoint answers and
  # which a client asks for right after registering itself, before it sends
  # anybody to a browser.
  #
  # Its own table rather than a row in `api_tokens`, and that is the whole
  # design decision. `api_tokens.user_id` is NOT NULL and
  # `Vutuv.ApiAuth.lookup/1` reaches the user through an **inner join**, so a
  # userless row there would be dropped by that join without a word — the shape
  # this project has been bitten by five times (see CLAUDE.md on widening a NOT
  # NULL column). Widening it would also mean an N-1 window in which the
  # previous release meets a token it cannot read.
  #
  # Keeping app tokens somewhere else buys the security property for free: every
  # member-scoped endpoint authenticates through `api_tokens`, so an app token
  # presented to one cannot be accepted — not because a check refuses it, but
  # because it is not in the table that path reads. A plain addition, so this
  # migration is N-1 safe on its own.
  def change do
    create table(:oauth_app_tokens) do
      add(:app_id, references(:oauth_apps, on_delete: :delete_all), null: false)
      # SHA-256 of a ~165-bit random token, like every other credential here:
      # the entropy is what protects it, so no pepper is needed (CLAUDE.md).
      add(:token_hash, :string, null: false)
      add(:scopes, {:array, :string}, null: false, default: [])
      add(:last_used_at, :utc_datetime)
      add(:revoked_at, :utc_datetime)

      timestamps()
    end

    create(unique_index(:oauth_app_tokens, [:token_hash]))
    create(index(:oauth_app_tokens, [:app_id]))
  end
end
