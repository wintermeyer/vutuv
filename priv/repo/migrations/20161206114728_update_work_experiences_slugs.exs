defmodule Vutuv.Repo.Migrations.UpdateWorkExperiencesSlugs do
  use Ecto.Migration

  # No-op. The original backfilled work-experience slugs via Vutuv.WorkExperience
  # (reorganized into Vutuv.Profiles.WorkExperience during the refactor). The
  # work_experiences table is empty at this point in the migration history, so the
  # loop never did any work.
  def change, do: :ok
end
