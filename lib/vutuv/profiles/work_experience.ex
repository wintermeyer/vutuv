defmodule Vutuv.Profiles.WorkExperience do
  @moduledoc false

  use VutuvWeb, :model
  import Ecto.Query

  # The CV categories (issue #840): a paid job, self-employment/freelance,
  # a Praktikum, an Ehrenamt, and a catch-all for anything else. Display order
  # everywhere is this list's order.
  @kinds ~w(employment self_employed internship volunteer other)

  schema "work_experiences" do
    field(:organization, :string)
    field(:title, :string)
    field(:description, :string)
    field(:kind, :string, default: "employment")
    field(:start_month, :integer)
    field(:start_year, :integer)
    field(:end_month, :integer)
    field(:end_year, :integer)
    field(:slug, :string)

    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end

  @cast_fields ~w(title description kind start_month start_year organization end_month end_year slug)a

  @doc "The known categories, in display order."
  def kinds, do: @kinds

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned
  with no validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @cast_fields)
    |> validate_required([:title, :organization, :kind])
    |> validate_inclusion(:kind, @kinds)
    # Match the varchar(255) columns (and cap the text description sanely) so
    # an oversized value is a changeset error, never a raised Postgres 22001 —
    # inside the import transaction that raise 500ed the whole import.
    |> validate_length(:title, max: 255)
    |> validate_length(:organization, max: 255)
    |> validate_length(:description, max: 10_000)
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
    # The slug derives from title + organization, so two near-cap values can
    # still overrun its own varchar(255) column.
    |> validate_length(:slug, max: 255)
    |> unique_constraint(:slug)
  end

  # The upper bound on a work-experience year, matching the form's year <select>
  # (@current_year..1920): a job can't start or end in a future year.
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
    if get_change(changeset, :title) || get_change(changeset, :organization) do
      model = %__MODULE__{
        title: get_field(changeset, :title),
        organization: get_field(changeset, :organization)
      }

      put_change(changeset, :slug, Vutuv.SlugHelpers.gen_slug_unique(model, :slug))
    else
      changeset
    end
  end

  @doc """
  Splits an already-ordered list into its CV categories: `{kind, entries}`
  pairs in `kinds/0` order (employment, internship, volunteer), empty
  categories dropped, the given (date) order kept within each. The shared
  grouping for every list rendering, so the profile card, the section page
  and the editor can never disagree on category order.
  """
  def group_by_kind(work_experiences) do
    groups = Enum.group_by(work_experiences, & &1.kind)

    for kind <- @kinds, entries = groups[kind], do: {kind, entries}
  end

  @doc """
  Newest first, the way a CV reads: ongoing roles (no end date) lead, then
  by end date, then by start date.

  Plain `DESC` does this in Postgres (DESC puts NULLs first). The previous
  `-? ASC` negation trick inverted the NULL placement and sorted the
  current, open-ended role **last**.
  """
  def order_by_date(query) do
    query
    |> order_by([u],
      desc: u.end_year,
      desc: u.end_month,
      desc: u.start_year,
      desc: u.start_month
    )
  end

  # Imported legacy entries can carry a NULL slug; falling back to the id
  # keeps their URLs (and the whole profile page) working instead of raising.
  defimpl Phoenix.Param, for: __MODULE__ do
    def to_param(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
    def to_param(%{id: id}), do: id
  end

  defimpl String.Chars, for: __MODULE__ do
    def to_string(job), do: "#{job.title} #{job.organization}"
  end

  defimpl List.Chars, for: __MODULE__ do
    def to_charlist(job), do: ~c"#{job.title} #{job.organization}"
  end
end
