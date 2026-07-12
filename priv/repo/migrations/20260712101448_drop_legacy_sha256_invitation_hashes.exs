defmodule Vutuv.Repo.Migrations.DropLegacySha256InvitationHashes do
  use Ecto.Migration

  # Issue #942: `invitations.email_hash` switched from an unsalted SHA-256 to a
  # keyed HMAC (`Vutuv.Invitations.hash_email/1`). The existing rows hold only
  # SHA-256 hashes: they can't be re-hashed (no plaintext is stored), they no
  # longer match any HMAC lookup, and an unsalted SHA-256 of a low-entropy email
  # is itself the privacy liability the switch fixes — so we drop them.
  #
  # Data-only change (no schema/column touched), so it stays N-1 compatible: the
  # previous release keeps serving fine against an empty dedup table (worst case
  # a low-harm duplicate invite in the switch window). Known recent invitees are
  # re-seeded with the new HMAC after deploy via
  # `Vutuv.Release.reseed_invitations/2`, from a plaintext list kept out of git.
  def up do
    execute("DELETE FROM invitations")
  end

  # Irreversible: the deleted rows carried only one-way SHA-256 hashes, so there
  # is nothing to restore.
  def down do
    :ok
  end
end
