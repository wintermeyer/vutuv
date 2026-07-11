defmodule Vutuv.Repo.Migrations.AddCompanyIdToWorkExperiences do
  use Ecto.Migration

  # Issue #931: a member may optionally link a work experience to a verified
  # company page. A plain nullable FK addition (N-1 safe): the previous release
  # never reads or writes the column. ON DELETE SET NULL so deleting a company
  # page quietly unlinks the experiences instead of cascading them away — the
  # free-text `organization` stays authoritative for display when unlinked.
  def change do
    alter table(:work_experiences) do
      add(:company_id, references(:companies, type: :binary_id, on_delete: :nilify_all))
    end

    # Powers the company page's "People" section (members whose linked
    # experience is at this company).
    create(index(:work_experiences, [:company_id]))
  end
end
