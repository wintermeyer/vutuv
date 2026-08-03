defmodule Vutuv.References.Link do
  @moduledoc """
  Ties one Arbeitszeugnis to one CV entry: a work experience, an education, or
  a qualification. A Zeugnis usually documents a single job, but an
  Ausbildungszeugnis belongs to an education entry, and one document can back
  both a role and the qualification earned in it — hence a join table rather
  than a column on `job_references`.

  Exactly one of the three subject columns is set. The database enforces that
  with a CHECK constraint; this schema enforces it too, so a member gets a
  changeset error instead of a raised `Ecto.ConstraintError`.
  """

  use VutuvWeb, :model

  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.Qualification
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.References.JobReference

  @subjects ~w(work_experience_id education_id qualification_id)a

  schema "job_reference_links" do
    belongs_to(:job_reference, JobReference)
    belongs_to(:work_experience, WorkExperience)
    belongs_to(:education, Education)
    belongs_to(:qualification, Qualification)

    timestamps()
  end

  @doc "The three subject foreign keys, exactly one of which a link carries."
  def subjects, do: @subjects

  @doc """
  Creates a changeset for a link.

  `job_reference_id` is set by the context from the row being edited, so it is
  not cast here.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @subjects)
    |> validate_exactly_one_subject()
    |> foreign_key_constraint(:work_experience_id)
    |> foreign_key_constraint(:education_id)
    |> foreign_key_constraint(:qualification_id)
    |> unique_constraint([:job_reference_id, :work_experience_id],
      name: :job_reference_links_work_experience_index
    )
    |> unique_constraint([:job_reference_id, :education_id],
      name: :job_reference_links_education_index
    )
    |> unique_constraint([:job_reference_id, :qualification_id],
      name: :job_reference_links_qualification_index
    )
  end

  defp validate_exactly_one_subject(changeset) do
    set = Enum.count(@subjects, &(not is_nil(get_field(changeset, &1))))

    case set do
      1 -> changeset
      0 -> add_error(changeset, :subject, "must point at one CV entry")
      _many -> add_error(changeset, :subject, "must point at exactly one CV entry")
    end
  end

  @doc """
  The `{kind, id}` pair a link carries, e.g. `{:work_experience, "019f…"}`.

  One place that answers "what does this link point at", so callers branch on
  a tagged tuple instead of testing three columns for nil.
  """
  def subject(%__MODULE__{work_experience_id: id}) when not is_nil(id), do: {:work_experience, id}
  def subject(%__MODULE__{education_id: id}) when not is_nil(id), do: {:education, id}
  def subject(%__MODULE__{qualification_id: id}) when not is_nil(id), do: {:qualification, id}
  def subject(%__MODULE__{}), do: nil
end
