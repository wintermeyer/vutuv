defmodule Vutuv.Repo.Migrations.DropGravatarImportedAtFromUsers do
  use Ecto.Migration

  @moduledoc """
  Drops `users.gravatar_imported_at`, the contract half of the expand/contract
  begun in v7.287.0.

  The column existed for one day. It was added in v7.285.0 to date an in-app
  note telling members that registration had quietly fetched their picture from
  gravatar.com; v7.287.0 removed that fetch entirely in favour of a button the
  member presses (issue #1447), which made the note — and so the column —
  pointless. Nothing has read or written it since that release, which is the
  one currently serving traffic, so dropping it now is N-1 compatible.

  It held exactly one value in production: a single sign-up caught in the three
  hours v7.285.0 was live. That one timestamp is not worth keeping — it records
  the reach of nothing, since the fetch itself ran silently for years before
  this column existed and left no marker anywhere. The member's avatar is
  untouched; only the timestamp goes.

  `remove/3` names the old type, so the migration rolls back cleanly (the value
  does not come back, which is fine — nothing reads it).
  """
  def change do
    alter table(:users) do
      remove(:gravatar_imported_at, :naive_datetime)
    end
  end
end
