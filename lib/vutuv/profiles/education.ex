defmodule Vutuv.Profiles.Education do
  @moduledoc false

  use VutuvWeb, :model
  alias Vutuv.ChangesetHelpers
  alias Vutuv.Mentions
  alias Vutuv.Profiles.CvSection

  # The CV categories (issue #849, mirroring WorkExperience's #840 kinds):
  # a degree, a Berufsausbildung, general schooling. Display order everywhere
  # is this list's order — the way a CV reads, highest attained first.
  @kinds ~w(university apprenticeship school)

  schema "educations" do
    field(:school, :string)
    field(:degree, :string)
    field(:field_of_study, :string)
    field(:description, :string)
    field(:kind, :string, default: "university")
    field(:start_month, :integer)
    field(:start_year, :integer)
    field(:end_month, :integer)
    field(:end_year, :integer)
    field(:slug, :string)
    # The author's "tell my followers about this" choice (issue #980), taken
    # once when the entry is created — `CvSection.cast_announcement/2` ignores
    # the param on an update. Deliberately NOT in @cast_fields.
    field(:announce_to_followers?, :boolean, default: false)

    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end

  @cast_fields ~w(school degree field_of_study description kind start_month start_year end_month end_year slug)a

  @doc "The known categories, in display order."
  def kinds, do: @kinds

  @doc """
  Splits an already-ordered list into its CV categories: `{kind, entries}`
  pairs in `kinds/0` order, empty categories dropped, the given (date) order
  kept within each — the same contract as `WorkExperience.group_by_kind/1`,
  so all list renderings of this section group identically.
  """
  def group_by_kind(educations), do: CvSection.group_by_kind(educations, @kinds)

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned
  with no validation performed.

  Unlike a work experience (which needs an organization *and* a title), an
  education entry only guarantees the school name — a LinkedIn export often
  carries a school with no degree — so `:school` is the sole required field.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @cast_fields)
    |> CvSection.cast_announcement(params)
    |> validate_required([:school, :kind])
    |> validate_inclusion(:kind, @kinds)
    # Match the varchar(255) columns (and cap the text description sanely) so
    # an oversized value is a changeset error, never a raised Postgres 22001 —
    # inside the import transaction that raise 500ed the whole import.
    |> validate_length(:school, max: 255)
    |> validate_length(:degree, max: 255)
    |> validate_length(:field_of_study, max: 255)
    |> validate_length(:description, max: 10_000)
    |> Mentions.validate_mentions_exist(:description)
    |> ChangesetHelpers.validate_period()
    |> CvSection.put_slug(__MODULE__, [:school, :degree])
    # The slug derives from the school name, so a near-cap value can still
    # overrun its own varchar(255) column.
    |> validate_length(:slug, max: 255)
    |> unique_constraint(:slug)
  end

  @doc """
  Newest first, the way a CV reads: ongoing studies (no end date) lead, then by
  end date, then by start date. Delegates to the shared `CvSection.order_by_date/1`,
  matching `WorkExperience.order_by_date/1`.
  """
  def order_by_date(query), do: CvSection.order_by_date(query)

  # Imported entries can carry a NULL slug; falling back to the id keeps their
  # URLs (and the whole profile page) working instead of raising.
  defimpl Phoenix.Param, for: __MODULE__ do
    def to_param(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
    def to_param(%{id: id}), do: id
  end

  defimpl String.Chars, for: __MODULE__ do
    def to_string(edu), do: "#{edu.degree} #{edu.school}"
  end

  defimpl List.Chars, for: __MODULE__ do
    def to_charlist(edu), do: ~c"#{edu.degree} #{edu.school}"
  end
end
