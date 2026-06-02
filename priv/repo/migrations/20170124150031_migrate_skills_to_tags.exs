defmodule Vutuv.Repo.Migrations.MigrateSkillsToTags do
  use Ecto.Migration

  # No-op on fresh databases. The original migration moved legacy "skills" data into the
  # tag system and referenced modules (Vutuv.Skill, Vutuv.Tag, Vutuv.UserSkill,
  # Vutuv.UserTag, Vutuv.Endorsement, Vutuv.UserTagEndorsement) that were reorganized into
  # context namespaces and partly removed during the refactor. Any database that needed
  # this one-time data migration already ran it years ago; on a fresh database all source
  # tables are empty, so it is safe as a no-op.
  def change, do: :ok
end
