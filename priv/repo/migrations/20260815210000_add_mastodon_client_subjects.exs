defmodule Vutuv.Repo.Migrations.AddMastodonClientSubjects do
  use Ecto.Migration

  # Additions only, and deliberately nothing that writes to existing rows: the
  # Mastodon adapter reuses the `publisher` role rather than introducing one, so
  # no role table has to be rewritten to keep anybody's access. Splitting
  # reading from curating is written up under "Team roles" in
  # docs/architecture/organizations.md and belongs to its own change.
  #
  # Both `organization_id` columns are ON DELETE CASCADE on purpose: a token
  # whose page is gone must disappear with it, or the left join behind
  # `Vutuv.MastodonApi.Access.authorize_token/2` would answer with a nil
  # organization and the token would quietly fall back to acting as the member
  # who owns it.
  def up do
    alter table(:users) do
      add(:mastodon_clients?, :boolean, null: false, default: true)
    end

    alter table(:organizations) do
      add(:mastodon_clients?, :boolean, null: false, default: true)
    end

    alter table(:oauth_auth_codes) do
      add(:organization_id, references(:organizations, on_delete: :delete_all))
    end

    alter table(:api_tokens) do
      add(:organization_id, references(:organizations, on_delete: :delete_all))
    end

    create(index(:oauth_auth_codes, [:organization_id]))
    create(index(:api_tokens, [:organization_id]))
  end

  def down do
    drop(index(:api_tokens, [:organization_id]))
    drop(index(:oauth_auth_codes, [:organization_id]))

    alter table(:api_tokens) do
      remove(:organization_id)
    end

    alter table(:oauth_auth_codes) do
      remove(:organization_id)
    end

    alter table(:organizations) do
      remove(:mastodon_clients?)
    end

    alter table(:users) do
      remove(:mastodon_clients?)
    end
  end
end
