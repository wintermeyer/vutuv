defmodule Vutuv.Repo.Migrations.RenameMagicLinksToLoginPins do
  use Ecto.Migration

  # Issue #759: magic links are gone. The table now stores only a one-time PIN,
  # so it is renamed to `login_pins` and loses its "magic" vocabulary. The PIN
  # is no longer kept in plaintext: `pin` now holds a peppered, salted HMAC and
  # `pin_salt` carries the per-PIN random salt. The single-use token column
  # (`magic_link`) is dropped entirely.
  #
  # Any in-flight magic links or plaintext PINs become invalid on deploy. That
  # is intentional (the move to PINs is total); a fresh PIN request mints a new,
  # properly hashed row.

  def up do
    # Stale rows carry old plaintext PINs / tokens that can no longer validate
    # (the new code requires a salt + peppered hash). Clear them so nothing
    # lingers in a half-migrated state.
    execute("DELETE FROM magic_links")

    rename(table(:magic_links), to: table(:login_pins))

    rename(table(:login_pins), :magic_link_type, to: :type)
    rename(table(:login_pins), :magic_link_created_at, to: :created_at)

    alter table(:login_pins) do
      remove(:magic_link)
      add(:pin_salt, :binary)
    end

    # Renaming the table left the unique index and FK constraint under their old
    # `magic_links_*` names. Bring them in line with the new table/column names.
    execute(
      "ALTER INDEX magic_links_user_id_magic_link_type_index RENAME TO login_pins_user_id_type_index"
    )

    execute(
      "ALTER TABLE login_pins RENAME CONSTRAINT magic_links_user_id_fkey TO login_pins_user_id_fkey"
    )
  end

  def down do
    execute(
      "ALTER TABLE login_pins RENAME CONSTRAINT login_pins_user_id_fkey TO magic_links_user_id_fkey"
    )

    execute(
      "ALTER INDEX login_pins_user_id_type_index RENAME TO magic_links_user_id_magic_link_type_index"
    )

    alter table(:login_pins) do
      remove(:pin_salt)
      add(:magic_link, :string)
    end

    rename(table(:login_pins), :created_at, to: :magic_link_created_at)
    rename(table(:login_pins), :type, to: :magic_link_type)

    rename(table(:login_pins), to: table(:magic_links))
  end
end
