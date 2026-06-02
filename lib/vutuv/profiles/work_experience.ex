defmodule Vutuv.Profiles.WorkExperience do
  @moduledoc false

  use VutuvWeb, :model
  import Ecto.Query
  @derive {Phoenix.Param, key: :slug}

  schema "work_experiences" do
    field(:organization, :string)
    field(:title, :string)
    field(:description, :string)
    field(:start_month, :integer)
    field(:start_year, :integer)
    field(:end_month, :integer)
    field(:end_year, :integer)
    field(:slug, :string)

    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end

  @cast_fields ~w(title description start_month start_year organization end_month end_year slug)a

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned
  with no validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @cast_fields)
    |> validate_required([:title, :organization])
    |> validate_dates
    |> create_slug
    |> unique_constraint(:slug)
  end

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

  defp presence_correct?(year, month) do
    cond do
      year && month -> true
      year -> true
      month -> false
      true -> true
    end
  end

  defp date_range_correct?(start, finish) do
    if start && finish do
      cond do
        start > finish -> false
        start <= finish -> true
      end
    else
      true
    end
  end

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

  def order_by_date(query) do
    query
    |> order_by([u], [
      fragment("-? ASC", u.end_year),
      fragment("-? ASC", u.end_month),
      fragment("-? ASC", u.start_year),
      fragment("-? ASC", u.start_month)
    ])
  end

  defimpl String.Chars, for: __MODULE__ do
    def to_string(job), do: "#{job.title} #{job.organization}"
  end

  defimpl List.Chars, for: __MODULE__ do
    def to_charlist(job), do: ~c"#{job.title} #{job.organization}"
  end
end
