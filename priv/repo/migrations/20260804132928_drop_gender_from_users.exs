defmodule Vutuv.Repo.Migrations.DropGenderFromUsers do
  @moduledoc """
  Contract half of the expand/contract pair started in
  `20260804082102_add_salutation_to_users`.

  That migration added `salutation`, copied the two addressable values over and
  deliberately left `gender` in place so the release serving traffic during the
  blue/green switch kept working. v7.229.0 is deployed and reads `salutation`
  only — nothing in the tree touches this column any more, and the schema has no
  such field — so the column can go.

  `up` is irreversible in the sense that matters: the values it drops were
  already copied, and `down` puts the column back empty rather than pretending
  otherwise. Anything that needed the old classification is gone with it by
  design, which is the point of the change (see
  `docs/architecture/settings-and-account.md`).
  """
  use Ecto.Migration

  def up do
    alter table(:users) do
      remove(:gender)
    end
  end

  def down do
    alter table(:users) do
      add(:gender, :string)
    end
  end
end
