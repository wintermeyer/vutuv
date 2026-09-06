defmodule Vutuv.Moderation.Report do
  @moduledoc false

  use VutuvWeb, :model

  @copyright "copyright"
  @categories ~w(family bullying spam copyright other)
  # A private message is not published, so there is nothing for a rights holder
  # to have taken down. Written as the exception rather than as a second list,
  # so a category added above cannot silently skip the message form.
  @message_categories @categories -- [@copyright]
  # Job postings get a specific first category; "family"/"bullying" rarely apply.
  @job_categories ~w(misleading_job spam copyright other)
  @max_note_length 2_000

  schema "moderation_reports" do
    field(:category, :string)
    field(:note, :string)
    field(:abusive?, :boolean, default: false)
    # Deliberately not stored: the changeset refuses the copyright category
    # without it, so a stored copyright report IS the record that the
    # declaration was made.
    field(:good_faith?, :boolean, virtual: true, default: false)

    belongs_to(:case, Vutuv.Moderation.Case)
    belongs_to(:reporter, Vutuv.Accounts.User)

    timestamps()
  end

  def categories, do: @categories

  @doc """
  The category for "this is not yours to publish". The one complaint that is a
  legal notice rather than a house-rule one, so several places downstream ask
  for it by name rather than by string.
  """
  def copyright_category, do: @copyright

  @doc "Whether this report — or this bare category string — is a copyright complaint."
  def copyright?(%__MODULE__{category: category}), do: copyright?(category)
  def copyright?(category), do: category == @copyright

  @doc """
  The note's character cap — the changeset's `validate_length` and the form's
  `maxlength` both read it, so they cannot disagree.
  """
  def max_note_length, do: @max_note_length

  @doc "The report categories offered for a given content type (wire string)."
  def categories_for("job_posting"), do: @job_categories
  def categories_for("message"), do: @message_categories
  def categories_for(_type), do: @categories

  @doc """
  Builds a report changeset. `content_type` (the wire string) restricts the
  accepted categories to the ones that type actually offers, so a crafted POST
  can't slip an off-type category (e.g. `misleading_job` on a profile report)
  past the form — the same `categories_for/1` gate the form renders from.

  Every message is a whole sentence addressed to the reporter, because the
  report form has no per-field error slots and shows them as one banner. They
  are extracted for translation through
  `VutuvWeb.ErrorHelpers.__error_message_extraction_anchors__/0`.
  """
  def changeset(report, params \\ %{}, content_type \\ nil) do
    pick_one = "Please pick a category."

    report
    |> cast(params, [:category, :note, :good_faith?])
    |> update_change(:note, &String.trim/1)
    |> validate_required([:category], message: pick_one)
    |> validate_inclusion(:category, categories_for(content_type), message: pick_one)
    |> validate_length(:note, max: @max_note_length, message: "Your note is too long.")
    |> validate_copyright_notice()
    |> unique_constraint([:case_id, :reporter_id])
  end

  # A copyright complaint only means something as a complete notice: which work
  # it is and where the original can be seen (the note), plus the reporter's
  # declaration that the use really is unauthorized. Both are checked here, at
  # the one place every report passes, so no route can file half a notice and
  # still get the freeze and the admin queue that the category buys.
  defp validate_copyright_notice(changeset) do
    if copyright?(get_field(changeset, :category)) do
      changeset
      |> validate_required([:note],
        message: "Please tell us which work it is and where the original can be seen."
      )
      |> validate_good_faith()
    else
      changeset
    end
  end

  # Spelled out rather than `validate_acceptance/3`, which only fires when the
  # parameter is present — and an unticked checkbox sends nothing at all.
  defp validate_good_faith(changeset) do
    if get_field(changeset, :good_faith?) do
      changeset
    else
      add_error(
        changeset,
        :good_faith?,
        "Please confirm that you are making this claim in good faith."
      )
    end
  end
end
