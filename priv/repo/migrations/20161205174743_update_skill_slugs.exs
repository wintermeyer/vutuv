defmodule Vutuv.Repo.Migrations.UpdateSkillSlugs do
  use Ecto.Migration

  def change do
    create unique_index(:skills, [:slug], unique: true)

    # The original data backfill (generating slugs for existing skills) referenced
    # Vutuv.Skill, which was reorganized into Vutuv.Profiles.Skill in the context-module
    # refactor. The skills table is always empty at this point in the migration history,
    # so the backfill was a no-op. Only the unique index DDL is required.
  end
end
