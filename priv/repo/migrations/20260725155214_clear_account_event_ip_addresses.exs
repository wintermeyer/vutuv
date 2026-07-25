defmodule Vutuv.Repo.Migrations.ClearAccountEventIpAddresses do
  use Ecto.Migration

  # The account-activity log no longer keeps an IP address (issue #1087's first
  # cut did). Step 1 of the expand/contract: this release's code neither writes
  # nor reads the column, and this wipes what the previous release stored, so the
  # data is gone the moment the deploy lands rather than waiting for the drop.
  #
  # N-1 safe: the release still serving traffic during the migration selects the
  # column and simply reads NULL. The column itself is dropped one release later
  # (DropAccountEventIpAddresses) — dropping it here would 500 that release.
  def up do
    execute("UPDATE account_events SET ip_address = NULL")
  end

  # Deliberately irreversible: the addresses are deleted, and a down migration
  # that pretended otherwise would be a lie.
  def down, do: :ok
end
