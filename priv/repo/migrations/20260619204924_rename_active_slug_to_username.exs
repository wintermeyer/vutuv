defmodule Vutuv.Repo.Migrations.RenameActiveSlugToUsername do
  use Ecto.Migration

  @moduledoc """
  Renames a member's handle from `active_slug` to `username` everywhere it
  lives in the database: the `users.active_slug` column and the
  `slug_changes` ledger table become `users.username` and `username_changes`.

  Pure renames — no data is moved or dropped, and every index/constraint is
  renamed alongside its object so nothing is orphaned. The `users` unique
  index is renamed to `users_username_index` specifically so
  `unique_constraint(:username)` keeps mapping the "username already taken"
  error to the field.

  Not N-1 / blue-green safe: the previous release still queries `active_slug`
  / `slug_changes`, so this ships as a deliberate planned-downtime deploy
  (like the UUID v7 re-key), never a casual push.
  """

  def up do
    # users.active_slug -> users.username
    rename(table(:users), :active_slug, to: :username)
    execute("ALTER INDEX users_active_slug_index RENAME TO users_username_index")

    # The username-change ledger: slug_changes -> username_changes, with its
    # index and primary/foreign-key constraints renamed to match.
    rename(table(:slug_changes), to: table(:username_changes))

    execute(
      "ALTER INDEX slug_changes_user_id_inserted_at_index RENAME TO username_changes_user_id_inserted_at_index"
    )

    execute(
      "ALTER TABLE username_changes RENAME CONSTRAINT slug_changes_pkey TO username_changes_pkey"
    )

    execute(
      "ALTER TABLE username_changes RENAME CONSTRAINT slug_changes_user_id_fkey TO username_changes_user_id_fkey"
    )
  end

  def down do
    execute(
      "ALTER TABLE username_changes RENAME CONSTRAINT username_changes_user_id_fkey TO slug_changes_user_id_fkey"
    )

    execute(
      "ALTER TABLE username_changes RENAME CONSTRAINT username_changes_pkey TO slug_changes_pkey"
    )

    execute(
      "ALTER INDEX username_changes_user_id_inserted_at_index RENAME TO slug_changes_user_id_inserted_at_index"
    )

    rename(table(:username_changes), to: table(:slug_changes))

    execute("ALTER INDEX users_username_index RENAME TO users_active_slug_index")
    rename(table(:users), :username, to: :active_slug)
  end
end
