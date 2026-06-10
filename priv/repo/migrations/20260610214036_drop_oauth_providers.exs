defmodule Vutuv.Repo.Migrations.DropOauthProviders do
  use Ecto.Migration

  # OAuth login was never implemented: the table has been an empty scaffold
  # since 2016 (login is PIN-over-email by design), and the schema module,
  # its has_many/cast_assoc and the preloads were dead weight on every user
  # edit/update. The Vutuv.Accounts.OAuthProvider module is gone with this.
  def up do
    drop(table(:oauth_providers))
  end

  def down do
    create table(:oauth_providers, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:provider_id, :string)
      add(:provider, :string)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all))

      timestamps()
    end
  end
end
