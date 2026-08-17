defmodule Vutuv.Repo.Migrations.AddMastodonOauthApps do
  use Ecto.Migration

  def up do
    # Mastodon's proprietary app-registration endpoint has no signed-in owner.
    # Dropping NOT NULL is backward-compatible with the previous release, whose
    # own registration path continues to write a user_id exactly as before.
    execute("ALTER TABLE oauth_apps ALTER COLUMN user_id DROP NOT NULL")

    alter table(:oauth_apps) do
      add(:protocol, :string, null: false, default: "vutuv")
      add(:registered_scopes, {:array, :string}, null: false, default: [])
    end

    create(index(:oauth_apps, [:protocol]))
  end

  def down do
    drop(index(:oauth_apps, [:protocol]))

    alter table(:oauth_apps) do
      remove(:registered_scopes)
      remove(:protocol)
    end

    # A downgrade is safe only while no unattended registration remains.
    execute("DELETE FROM oauth_apps WHERE user_id IS NULL")
    execute("ALTER TABLE oauth_apps ALTER COLUMN user_id SET NOT NULL")
  end
end
