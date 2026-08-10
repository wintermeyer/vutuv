defmodule Vutuv.Repo.Migrations.WidenOrganizationRoleUniqueIndex do
  @moduledoc """
  Issue #1333, step 1 of 2. A member holds exactly one role per organization
  today because of the unique index on `[organization_id, user_id]`. The
  `publisher` role only means something if it can be held *beside* `owner` or
  `admin`, so the pair has to become a triple.

  This step only **adds** `[organization_id, user_id, role]`; the old pair index
  stays and keeps enforcing one-role-per-member for one more deploy. Dropping it
  here would not be safe, contrary to what the issue assumed: the previous
  release is still serving traffic while migrations run, its roster still inserts
  role rows, and with the pair index gone its own "already on the team" refusal
  disappears with it — so it could write the second row that its own
  `role_of/2` (`Repo.one`) then raises on. The drop ships in the next deploy,
  by which time every release in play reads roles as a list.
  """
  use Ecto.Migration

  def change do
    create(unique_index(:organization_roles, [:organization_id, :user_id, :role]))
  end
end
