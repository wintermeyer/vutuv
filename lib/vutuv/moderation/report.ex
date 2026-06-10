defmodule Vutuv.Moderation.Report do
  @moduledoc false

  use VutuvWeb, :model

  @categories ~w(family bullying spam other)
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

  def changeset(report, params \\ %{}) do
    report
    |> cast(params, [:category, :note])
    |> update_change(:note, &String.trim/1)
    |> validate_required([:category])
    |> validate_inclusion(:category, @categories)
    |> validate_length(:note, max: @max_note_length)
    |> unique_constraint([:case_id, :reporter_id])
  end
end
