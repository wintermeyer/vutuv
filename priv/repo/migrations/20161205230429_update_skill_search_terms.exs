defmodule Vutuv.Repo.Migrations.UpdateSkillSearchTerms do
  use Ecto.Migration

  # No-op. The original backfilled skill search terms via Vutuv.Skill / Vutuv.SearchTerm
  # (reorganized into context modules during the refactor). The skills table is empty at
  # this point in the migration history, so the loop never did any work.
  def change, do: :ok
end
