defmodule Vutuv.Repo.Migrations.AddGravatarImportedAtToUsers do
  use Ecto.Migration

  # When registration actually imported an avatar from gravatar.com for this
  # member (issue #1447) — stamped by `Vutuv.Accounts.store_gravatar/1` only on
  # the path where an image was stored, never on the 404/error paths. It is the
  # timestamp of the "we found a picture for your address" note in the
  # notifications feed (`Vutuv.Activity`), and NULL means "no such note": every
  # account whose avatar arrived that way before this feature keeps a clean
  # feed rather than being told about an import from years ago.
  #
  # A plain nullable addition, so the currently deployed release keeps working
  # unchanged (N-1).
  def change do
    alter table(:users) do
      add(:gravatar_imported_at, :naive_datetime)
    end
  end
end
