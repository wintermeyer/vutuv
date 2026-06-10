defmodule Vutuv.Repo.Migrations.SimplifyUsernamesDropSlugs do
  use Ecto.Migration

  @moduledoc """
  Usernames keep it simple now: `users.active_slug` is the one live handle
  (unique), changing it just renames the account. Old handles are neither
  reserved nor redirected, so the `slugs` history table goes away. What
  remains is `slug_changes`, a small ledger of when a member changed their
  handle, which backs the rate limit (4 changes per rolling 90 days).
  """

  def up do
    create(unique_index(:users, [:active_slug]))

    create table(:slug_changes) do
      add(:value, :string, null: false)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      timestamps()
    end

    # The quota query: this user's changes within the last 90 days.
    create(index(:slug_changes, [:user_id, :inserted_at]))

    drop(table(:slugs))
  end

  def down do
    # The slugs rows (handle history, redirects, reservations) are deliberately
    # destroyed - recreating the empty table keeps a rollback from crashing,
    # but the data is gone.
    create table(:slugs) do
      add(:value, :string)
      add(:disabled, :boolean, default: false)
      add(:user_id, references(:users, on_delete: :delete_all))
      timestamps()
    end

    create(unique_index(:slugs, [:value]))

    drop(table(:slug_changes))
    drop(unique_index(:users, [:active_slug]))
  end
end
