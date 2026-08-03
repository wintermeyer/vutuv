defmodule Vutuv.Repo.Migrations.CreateJobReferenceLinks do
  use Ecto.Migration

  @moduledoc """
  Which CV entries a Zeugnis belongs to. A Zeugnis usually documents one job,
  but not always: an Ausbildungszeugnis covers an education entry, and one
  document can cover a role plus the qualification earned in it.

  Three nullable foreign keys with a CHECK that exactly one is set, rather
  than a `(subject_kind, subject_id)` pair. The pair reads tidier and buys
  nothing here: it cannot cascade, so deleting a work experience would leave a
  link pointing at a row that is gone, and every read would need a runtime
  branch anyway. Three real foreign keys let Postgres clean up after itself.
  """

  def change do
    create table(:job_reference_links) do
      add(
        :job_reference_id,
        references(:job_references, on_delete: :delete_all, type: :binary_id),
        null: false
      )

      add(
        :work_experience_id,
        references(:work_experiences, on_delete: :delete_all, type: :binary_id)
      )

      add(:education_id, references(:educations, on_delete: :delete_all, type: :binary_id))

      add(
        :qualification_id,
        references(:qualifications, on_delete: :delete_all, type: :binary_id)
      )

      timestamps()
    end

    create(index(:job_reference_links, [:job_reference_id]))

    # One link per (Zeugnis, CV entry). Partial, because two links to
    # *different* kinds both leave the other columns NULL, and NULLs do not
    # collide in a plain unique index — so a single three-column index would
    # not stop a duplicate.
    create(
      unique_index(:job_reference_links, [:job_reference_id, :work_experience_id],
        where: "work_experience_id IS NOT NULL",
        name: :job_reference_links_work_experience_index
      )
    )

    create(
      unique_index(:job_reference_links, [:job_reference_id, :education_id],
        where: "education_id IS NOT NULL",
        name: :job_reference_links_education_index
      )
    )

    create(
      unique_index(:job_reference_links, [:job_reference_id, :qualification_id],
        where: "qualification_id IS NOT NULL",
        name: :job_reference_links_qualification_index
      )
    )

    # Reading the other direction: "which Zeugnisse back this CV entry?" is
    # what the profile renders, once per entry on the page.
    create(index(:job_reference_links, [:work_experience_id]))
    create(index(:job_reference_links, [:education_id]))
    create(index(:job_reference_links, [:qualification_id]))

    # Exactly one subject per row. The schema validates this too, but the
    # constraint is what makes it true — a link with none set would be an
    # orphan the profile silently drops, one with two would render twice.
    create(
      constraint(:job_reference_links, :job_reference_links_exactly_one_subject,
        check: """
        (CASE WHEN work_experience_id IS NULL THEN 0 ELSE 1 END)
          + (CASE WHEN education_id IS NULL THEN 0 ELSE 1 END)
          + (CASE WHEN qualification_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )
  end
end
