defmodule Vutuv.Jobs.JobPostingTag do
  @moduledoc """
  A tag on a job posting, with a `priority` splitting the detail page's
  "Erforderlich" (required) from "Wünschenswert" (nice_to_have) sections. Tags
  are attached through the `Vutuv.Tags` chokepoints (case rules, honor tags
  excluded); this join only carries the priority and the composite uniqueness.
  """
  use VutuvWeb, :model

  @priorities [:required, :nice_to_have]

  schema "job_posting_tags" do
    field(:priority, Ecto.Enum, values: @priorities, default: :required)
    belongs_to(:job_posting, Vutuv.Jobs.JobPosting)
    belongs_to(:tag, Vutuv.Tags.Tag)

    timestamps()
  end

  def priorities, do: @priorities

  def changeset(job_posting_tag, params \\ %{}) do
    job_posting_tag
    |> cast(params, [:tag_id, :priority])
    |> validate_required([:tag_id, :priority])
    |> unique_constraint(:tag_id, name: :job_posting_tags_job_posting_id_tag_id_index)
  end
end
