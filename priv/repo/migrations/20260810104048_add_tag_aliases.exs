defmodule Vutuv.Repo.Migrations.AddTagAliases do
  use Ecto.Migration

  # Issue #1338: a topic spread over several tags that share no letters
  # (`Ruby on Rails` / `rails` / `ROR` / `rubyonrails`) becomes one canonical
  # tag carrying the others as alternative names.
  #
  # An alias is a tag row pointing at its canonical rather than a row in a
  # separate names table, which buys three things at once: the absorbed slug
  # keeps resolving because the row that owns it is still there (this is the
  # slug history #1332 planned), the absorbed id survives so a merge can be
  # reverted exactly, and an alias cannot collide with a real tag because both
  # live under the same unique index on `slug`.
  #
  # Additive only, so the currently deployed release keeps working: it does not
  # know the columns and simply goes on treating every tag as canonical.
  def change do
    alter table(:tags) do
      add(:merged_into_id, references(:tags, type: :binary_id, on_delete: :nilify_all))
      add(:alias_kind, :string)
    end

    # Every tag listing filters on this column, and the canonical page looks up
    # its own aliases by it.
    create(index(:tags, [:merged_into_id]))
  end
end
