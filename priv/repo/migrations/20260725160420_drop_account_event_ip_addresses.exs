defmodule Vutuv.Repo.Migrations.DropAccountEventIpAddresses do
  use Ecto.Migration

  # Step 2 of the expand/contract that took the IP address out of the
  # account-activity log (issue #1087). The previous release already stopped
  # writing and reading this column and nulled every value in it
  # (ClearAccountEventIpAddresses), so the release still serving traffic while
  # this runs never touches it and the drop is N-1 safe.
  #
  # `change` rather than up/down: the rollback re-adds an empty nullable column,
  # which is exactly the state the previous release is happy with.
  def change do
    alter table(:account_events) do
      remove(:ip_address, :string)
    end
  end
end
