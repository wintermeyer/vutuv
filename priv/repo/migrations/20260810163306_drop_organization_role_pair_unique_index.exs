defmodule Vutuv.Repo.Migrations.DropOrganizationRolePairUniqueIndex do
  @moduledoc """
  Issue #1333, step 2 of 2. The previous deploy added the
  `[organization_id, user_id, role]` unique index and taught every reader to
  take a list of roles (`roles_of/2`). Now the old pair index goes, so a member
  can hold `publisher` beside `owner` or `admin`.

  Safe as an N-1 step because the release still serving traffic during this
  migration is the one that already reads roles as a list, so a second row for a
  member means nothing worse to it than a longer list.
  """
  use Ecto.Migration

  def change do
    drop(unique_index(:organization_roles, [:organization_id, :user_id]))
  end
end
