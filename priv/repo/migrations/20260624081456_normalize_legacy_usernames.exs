defmodule Vutuv.Repo.Migrations.NormalizeLegacyUsernames do
  use Ecto.Migration

  alias Vutuv.Accounts

  # Brings every legacy handle into line with the Twitter-style username rule
  # (^[a-z0-9_]+$, max 15 chars): the dotted / over-length imports from the old
  # vutuv get a valid handle regenerated from the member's name, and the old
  # handle is preserved in users.legacy_username so it is never lost and the old
  # profile URL 301s to the new one. The work lives in
  # Vutuv.Accounts.normalize_legacy_usernames/0.
  #
  # Data-only (no DDL), so it runs in the implicit transaction: the rename is
  # all-or-nothing, which is what the blue/green deploy wants. A fresh / test
  # database has no members, so it is a no-op there - the real work only
  # happens against the production data.
  def up do
    renamed = Accounts.normalize_legacy_usernames()
    IO.puts("normalized #{renamed} legacy username(s)")
  end

  # Restores each renamed member's original handle from the legacy_username we
  # stashed, then clears the column - the one case where the rename *is*
  # reversible, because the old handle was preserved. (A member who has since
  # changed their handle again keeps that newer one; this only rolls back
  # rows still sitting on the minted handle.)
  def down do
    execute("""
    UPDATE users
       SET username = legacy_username, legacy_username = NULL
     WHERE legacy_username IS NOT NULL
    """)
  end
end
