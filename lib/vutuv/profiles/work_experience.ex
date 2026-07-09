defmodule Vutuv.Profiles.WorkExperience do
  @moduledoc false

  use VutuvWeb, :model
  import Ecto.Query
  alias Vutuv.ChangesetHelpers

  # The CV categories (issue #840): a paid job, self-employment/freelance,
  # a Praktikum, volunteering (Ehrenamt, hobby or Freiwilligenarbeit, issue
  # #916), and a catch-all for anything else. Display order everywhere is this
  # list's order.
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
    |> ChangesetHelpers.validate_period()
    |> create_slug
    # The slug derives from title + organization, so two near-cap values can
    # still overrun its own varchar(255) column.
    |> validate_length(:slug, max: 255)
    |> unique_constraint(:slug)
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
