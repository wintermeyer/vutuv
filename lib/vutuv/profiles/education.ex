defmodule Vutuv.Profiles.Education do
  @moduledoc false

  use VutuvWeb, :model
  import Ecto.Query

  schema "educations" do
    field(:school, :string)
    field(:degree, :string)
    field(:field_of_study, :string)
    field(:description, :string)
    field(:start_month, :integer)
    field(:start_year, :integer)
    field(:end_month, :integer)
    field(:end_year, :integer)
    field(:slug, :string)

    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end

  @cast_fields ~w(school degree field_of_study description start_month start_year end_month end_year slug)a

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
    |> validate_required([:school])
    |> validate_dates
    |> validate_inclusion(:start_month, 1..12)
    |> validate_inclusion(:end_month, 1..12)
    |> validate_number(:start_year,
      greater_than_or_equal_to: 1920,
      less_than_or_equal_to: current_year()
    )
    |> validate_number(:end_year,
      greater_than_or_equal_to: 1920,
      less_than_or_equal_to: current_year()
    )
    |> create_slug
    |> unique_constraint(:slug)
  end

  # The upper bound on an education year, matching the form's year <select>
  # (@current_year..1920): a study period can't start or end in a future year.
  defp current_year, do: Date.utc_today().year

  def validate_dates(changeset) do
    end_month = get_field(changeset, :end_month)
    end_year = get_field(changeset, :end_year)
    start_month = get_field(changeset, :start_month)
    start_year = get_field(changeset, :start_year)

    changeset =
      if presence_correct?(start_year, start_month),
        do: changeset,
        else: add_error(changeset, :start_year, "If month is present, year must be present.")

    changeset =
      if presence_correct?(end_year, end_month),
        do: changeset,
        else: add_error(changeset, :end_year, "If month is present, year must be present.")

    changeset =
      if date_range_correct?(start_year, end_year),
        do: changeset,
        else: add_error(changeset, :end_month, "End date must be later than start date")

    if start_year && end_year && start_year == end_year do
      if date_range_correct?(start_month, end_month),
        do: changeset,
        else: add_error(changeset, :end_month, "End date must be later than start date")
    else
      changeset
    end
  end

  # A month without a year is the only invalid combination.
  defp presence_correct?(year, month) do
    not is_nil(year) or is_nil(month)
  end

  defp date_range_correct?(start, finish) when is_nil(start) or is_nil(finish), do: true
  defp date_range_correct?(start, finish), do: start <= finish

  defp create_slug(changeset) do
    if get_change(changeset, :school) || get_change(changeset, :degree) do
      model = %__MODULE__{
        school: get_field(changeset, :school),
        degree: get_field(changeset, :degree)
      }

      put_change(changeset, :slug, Vutuv.SlugHelpers.gen_slug_unique(model, :slug))
    else
      changeset
    end
  end

  @doc """
  Newest first, the way a CV reads: ongoing studies (no end date) lead, then
  by end date, then by start date. Plain `DESC` does this in Postgres (DESC
  puts NULLs first), matching `WorkExperience.order_by_date/1`.
  """
  def order_by_date(query) do
    query
    |> order_by([e],
      desc: e.end_year,
      desc: e.end_month,
      desc: e.start_year,
      desc: e.start_month
    )
  end

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
