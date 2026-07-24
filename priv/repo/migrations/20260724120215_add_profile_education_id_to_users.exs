defmodule Vutuv.Repo.Migrations.AddProfileEducationIdToUsers do
  use Ecto.Migration

  # The education a member pinned as their profile headline (issue #882): the
  # "Degree, School" line that leads the profile instead of a job title, for a
  # student or someone unemployed who wants to feature a school over a role.
  # NULL = no education pinned (today's behaviour, the header falls back to the
  # work-experience resolution), so this is a plain, backward-compatible
  # addition the currently deployed release simply ignores. It is the education
  # twin of profile_work_experience_id (issue #833); the two are mutually
  # exclusive in the pin-setting code, not the schema. ON DELETE SET NULL means
  # deleting the pinned entry clears the pointer, so the header can never point
  # at a gone education. The index keeps that SET NULL cascade (and any lookup)
  # off a users seq scan.
  def change do
    alter table(:users) do
      add(:profile_education_id,
        references(:educations, on_delete: :nilify_all, type: :binary_id)
      )
    end

    create(index(:users, [:profile_education_id]))
  end
end
