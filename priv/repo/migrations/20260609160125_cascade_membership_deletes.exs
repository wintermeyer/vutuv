defmodule Vutuv.Repo.Migrations.CascadeMembershipDeletes do
  use Ecto.Migration

  @moduledoc """
  A membership is a join row that cannot outlive either parent: it groups one
  of the owner's follow edges (`follow_id`) into one of the owner's groups
  (`group_id`). Both FKs were `ON DELETE NO ACTION`, which meant deleting an
  account that owned a group with members — or whose follow edge sat in a
  group — aborted the whole cascade with a foreign-key violation (`follows`
  and `groups` both cascade from the user, but the dangling membership blocked
  them). Cascading the membership with either parent removes that wall and is
  the correct lifecycle anyway: an orphaned membership has no meaning.

  The `follow_id` constraint still carries its pre-rename name
  (`memberships_connection_id_fkey`); renaming the column never renamed it.
  """

  def up do
    drop(constraint(:memberships, "memberships_connection_id_fkey"))
    drop(constraint(:memberships, "memberships_group_id_fkey"))

    alter table(:memberships) do
      modify(:follow_id, references(:follows, on_delete: :delete_all))
      modify(:group_id, references(:groups, on_delete: :delete_all))
    end
  end

  def down do
    drop(constraint(:memberships, "memberships_follow_id_fkey"))
    drop(constraint(:memberships, "memberships_group_id_fkey"))

    alter table(:memberships) do
      modify(:follow_id, references(:follows, on_delete: :nothing))
      modify(:group_id, references(:groups, on_delete: :nothing))
    end
  end
end
