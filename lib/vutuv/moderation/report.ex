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
  # A profile picture or cover (issue #2012). Copyright is the point of the
  # type, and a picture can as easily be the family-friendliness or the
  # harassment complaint. Spam is left out deliberately: an advert as a profile
  # picture is a complaint about the account, and that report — which the spam
  # auto-defense counts towards freezing a whole profile — belongs on the
  # profile, not on one of its pictures.
  @image_categories ~w(family bullying copyright other)
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
    # Nullable since issue #2009: a rights holder without an account files
    # through `/system/report` and is identified by a confirmed address
    # instead. Exactly one of the two is set (a CHECK constraint, not a
    # convention).
    belongs_to(:reporter, Vutuv.Accounts.User)

    # The outside notifier. Stored in the clear, because an admin has to be
    # able to write back; shown to admins only, never to the owner of the
    # reported content.
    field(:reporter_email, :string)
    field(:reporter_name, :string)

    # The receipt mail's confirmation link. Until it is followed the notice
    # counts for nothing (`effective?/1`): the case sits `flagged` in the admin
    # queue and nothing is hidden.
    field(:confirmation_hash, :string)
    field(:confirmed_at, :naive_datetime)

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

  @doc """
  Whether this report counts for anything yet.

  A member's report always does. An **outside** notice only does once its
  address has been confirmed — before that it is a stranger's unverified claim,
  and every tally that can hide content (the trust ladder, the profile-freeze
  count, the spam auto-defense) filters on this. Without it five unconfirmed
  submissions would freeze any profile, which is the abuse a public form buys
  if nobody says no.
  """
  def effective?(%__MODULE__{reporter_id: id}) when is_binary(id), do: true
  def effective?(%__MODULE__{confirmed_at: %NaiveDateTime{}}), do: true
  def effective?(%__MODULE__{}), do: false

  @doc "The report categories offered for a given content type (wire string)."
  def categories_for("job_posting"), do: @job_categories
  def categories_for("image"), do: @image_categories
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

  @doc """
  A report filed through the public form at `/system/report` by somebody who
  has no account here (issue #2009).

  Three things are stricter than for a member. Every category needs the written
  explanation and the good-faith declaration, not only `copyright`: a member is
  identified by their account and answerable through it, a stranger is
  answerable only through what they wrote and the address they confirmed. And
  the name and the address are required, because the notice is worth nothing to
  an admin without a way back to the person who sent it.
  """
  def outside_changeset(report, params, content_type) do
    report
    |> changeset(params, content_type)
    |> cast(params, [:reporter_name, :reporter_email])
    |> update_change(:reporter_name, &String.trim/1)
    |> update_change(:reporter_email, fn value -> value |> String.trim() |> String.downcase() end)
    |> validate_required([:reporter_name], message: "Please tell us your name.")
    |> validate_required([:reporter_email], message: "Please give us an email address.")
    |> validate_format(:reporter_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "That does not look like an email address."
    )
    # The RFC 5321 address cap, inside the varchar(255) column: an oversized
    # value must be a changeset error, never a raised Postgres 22001.
    |> validate_length(:reporter_email, max: 254, message: "That address is too long.")
    |> validate_length(:reporter_name, max: 255, message: "Your name is too long.")
    |> validate_required([:note],
      message: "Please tell us what is wrong with this content, in your own words."
    )
    |> validate_good_faith()
    |> unique_constraint(:reporter_email,
      name: :moderation_reports_case_reporter_email_index,
      message: "You already reported this."
    )
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
