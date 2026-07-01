defmodule Vutuv.Repo.Migrations.AddProfileWorkExperienceToUsers do
  use Ecto.Migration

  # The work experience a member pinned as their profile job title (issue #833).
  # NULL = fall back to the automatic heuristic (today's behaviour), so this is
  # a plain, backward-compatible addition: the currently deployed release simply
  # ignores the column. ON DELETE SET NULL means deleting the pinned role clears
  # the pointer, so the header can never point at a gone experience. The index
  # keeps that SET NULL cascade (and any future lookup) off a users seq scan.
  def change do
    alter table(:users) do
      add(:profile_work_experience_id,
        references(:work_experiences, on_delete: :nilify_all, type: :binary_id)
      )
    end

    create(index(:users, [:profile_work_experience_id]))
  end
end
