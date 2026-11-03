defmodule Vutuv.Profiles.Publication do
  @moduledoc """
  A publication a member authored or co-authored (issue #2350): a paper, a
  book chapter, a talk's proceedings, a report. The section exists for the
  academic members an ORCID iD brought in, but it is deliberately plain — a
  title, the co-authors as free text, where it appeared, when, a link — so a
  journalist's articles or an engineer's conference talks fit the same shape.

  Entries read newest first like the other CV sections (`ordered/1`), and a
  new one may announce itself to the member's followers the way a new job or
  certificate does (issue #980, `Vutuv.Profiles.CvUpdates`).
  """

  use VutuvWeb, :model

  import Ecto.Query
  import Vutuv.ChangesetHelpers, only: [trim_fields: 2, validate_url: 2]

  alias Vutuv.BerlinTime
  alias Vutuv.Mentions
  alias Vutuv.Profiles.CvSection

  schema "publications" do
    field(:title, :string)
    field(:authors, :string)
    field(:publisher, :string)
    field(:published_month, :integer)
    field(:published_year, :integer)
    field(:url, :string)
    field(:description, :string)
    field(:slug, :string)
    # The author's "tell my followers about this" choice (issue #980), taken
    # once when the entry is created — `CvSection.cast_announcement/2` ignores
    # the param on an update. Deliberately NOT in @cast_fields.
    field(:announce_to_followers?, :boolean, default: false)

    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end

  @cast_fields ~w(title authors publisher published_month published_year url description)a

  # A bare DOI ("10.1000/xyz123", with or without a "doi:" prefix), which is
  # how a paper is cited and what a member is likeliest to paste.
  @doi ~r/^(?:doi:\s*)?(10\.\d{4,9}\/\S+)$/i

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned with no
  validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @cast_fields)
    |> trim_fields([:title, :authors, :publisher, :url])
    |> CvSection.cast_announcement(params)
    |> validate_required([:title])
    # Match the columns (varchar(255) unless text) so an oversized value is a
    # changeset error, never a raised Postgres 22001 — inside the import
    # transaction that raise would abort the whole import.
    |> validate_length(:title, max: 255)
    |> validate_length(:authors, max: 2_000)
    |> validate_length(:publisher, max: 255)
    |> validate_length(:url, max: 2_048)
    |> validate_length(:description, max: 10_000)
    |> Mentions.validate_mentions_exist(:description)
    |> validate_dates()
    |> normalize_doi()
    |> validate_url(:url)
    |> CvSection.put_slug(__MODULE__, [:title])
    # The slug derives from the title, so a near-cap title can still overrun
    # its own varchar(255) column.
    |> validate_length(:slug, max: 255)
    |> unique_constraint(:slug)
  end

  # A paper is dated by its issue, so a month without a year is a half date.
  # The year may run one ahead: "in press" for next year's volume is common.
  defp validate_dates(changeset) do
    changeset
    |> validate_inclusion(:published_month, 1..12)
    |> validate_number(:published_year,
      greater_than_or_equal_to: 1900,
      less_than_or_equal_to: BerlinTime.today().year + 1
    )
    |> validate_month_needs_year()
  end

  defp validate_month_needs_year(changeset) do
    if is_nil(get_field(changeset, :published_year)) and
         not is_nil(get_field(changeset, :published_month)) do
      add_error(changeset, :published_year, "If month is present, year must be present.")
    else
      changeset
    end
  end

  # A DOI pasted bare becomes its resolver address, so the link field takes
  # the citation form without the member knowing about doi.org.
  defp normalize_doi(changeset) do
    case get_change(changeset, :url) do
      url when is_binary(url) ->
        case Regex.run(@doi, url) do
          [_whole, doi] -> put_change(changeset, :url, "https://doi.org/" <> doi)
          nil -> changeset
        end

      _none ->
        changeset
    end
  end

  @doc """
  Entries in display order: most recently published first (the way a CV
  reads), undated entries last, then alphabetically by title so the order is
  stable.
  """
  def ordered(query \\ __MODULE__) do
    order_by(query, [p],
      desc_nulls_last: p.published_year,
      desc_nulls_last: p.published_month,
      asc: p.title
    )
  end

  # Imported entries can carry a NULL slug; falling back to the id keeps their
  # URLs (and the whole profile page) working instead of raising.
  defimpl Phoenix.Param, for: __MODULE__ do
    def to_param(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
    def to_param(%{id: id}), do: id
  end

  defimpl String.Chars, for: __MODULE__ do
    def to_string(publication), do: publication.title || ""
  end
end
