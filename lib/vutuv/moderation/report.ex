defmodule Vutuv.Moderation.Report do
  @moduledoc false

  use VutuvWeb, :model

  @categories ~w(family bullying spam other)
  # Job postings get a specific first category; "family"/"bullying" rarely apply.
  @job_categories ~w(misleading_job spam other)
  @all_categories Enum.uniq(@categories ++ @job_categories)
  @max_note_length 2_000

  schema "moderation_reports" do
    field(:category, :string)
    field(:note, :string)
    field(:abusive?, :boolean, default: false)

    belongs_to(:case, Vutuv.Moderation.Case)
    belongs_to(:reporter, Vutuv.Accounts.User)

    timestamps()
  end

  def categories, do: @categories

  @doc "The report categories offered for a given content type (wire string)."
  def categories_for("job_posting"), do: @job_categories
  def categories_for(_type), do: @categories

  def changeset(report, params \\ %{}) do
    report
    |> cast(params, [:category, :note])
    |> update_change(:note, &String.trim/1)
    |> validate_required([:category])
    |> validate_inclusion(:category, @all_categories)
    |> validate_length(:note, max: @max_note_length)
    |> unique_constraint([:case_id, :reporter_id])
  end
end
