defmodule Vutuv.Repo.Migrations.AddQualificationToWorkExperiences do
  use Ecto.Migration

  # Issue #858: a member may optionally cite, on a work experience, the
  # credential they earned the job with. A plain nullable FK addition (N-1
  # safe): the previous release never reads or writes the column. ON DELETE
  # SET NULL so deleting a credential quietly unlinks the jobs it backed
  # instead of cascading them away.
  def change do
    alter table(:work_experiences) do
      add(:qualification_id, references(:qualifications, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:work_experiences, [:qualification_id]))
  end
end
