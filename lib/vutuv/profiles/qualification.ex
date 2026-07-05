defmodule Vutuv.Profiles.Qualification do
  @moduledoc """
  A certificate or licence a member holds (issue #859): an AWS certification,
  an Approbation, a Scrum Master badge — a credential with an issuer and,
  unlike a degree, no school period and an optional expiry.

  Kept deliberately separate from `Vutuv.Profiles.Education`: this is purely
  additive and touches nothing that already works. The nullable `education_id`
  is a seam for issue #857 (folding degrees into this table later); it is
  always NULL today.
  """

  use VutuvWeb, :model
  import Ecto.Query
  import Vutuv.ChangesetHelpers, only: [validate_url: 2]

  alias Vutuv.BerlinTime

  # The two kinds a member picks between. A LinkedIn import lands everything as
  # a certification (LinkedIn has no signal separating a licence from a cert).
  @kinds ~w(certification license)

  schema "qualifications" do
    field(:name, :string)
    field(:kind, :string, default: "certification")
    field(:issuer, :string)
    field(:awarded_month, :integer)
    field(:awarded_year, :integer)
    field(:expires_month, :integer)
    field(:expires_year, :integer)
    field(:credential_id, :string)
    field(:url, :string)

    belongs_to(:user, Vutuv.Accounts.User)
    # Reserved for issue #857; always nil now, so it is not cast.
    belongs_to(:education, Vutuv.Profiles.Education)

    timestamps()
  end

  @cast_fields ~w(name kind issuer awarded_month awarded_year expires_month expires_year credential_id url)a

  @doc "The known kinds (certification | license)."
  def kinds, do: @kinds

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned with no
  validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @cast_fields)
    |> validate_required([:name, :kind])
    |> validate_inclusion(:kind, @kinds)
    # Match the varchar(255) columns so an oversized value (a long LinkedIn
    # certification name) is a changeset error, never a raised Postgres 22001 —
    # inside the import transaction that raise would abort the whole import.
    |> validate_length(:name, max: 255)
    |> validate_length(:issuer, max: 255)
    |> validate_length(:credential_id, max: 255)
    |> validate_length(:url, max: 255)
    |> validate_dates()
    # Only http(s), so the display-only link can never smuggle a javascript:
    # href onto the public profile (validate_url skips a nil/blank value).
    |> validate_url(:url)
  end

  # The awarded date can't be in the future; the expiry can (a cert valid until
  # 2030). A month always needs its year, and an expiry must not precede the
  # award. Kept local rather than sharing Education's `validate_period/1`, whose
  # start/end field names and current-year cap don't fit an awarded/expires pair.
  defp validate_dates(changeset) do
    changeset
    |> validate_inclusion(:awarded_month, 1..12)
    |> validate_inclusion(:expires_month, 1..12)
    |> validate_number(:awarded_year,
      greater_than_or_equal_to: 1920,
      less_than_or_equal_to: BerlinTime.today().year
    )
    |> validate_number(:expires_year,
      greater_than_or_equal_to: 1920,
      less_than_or_equal_to: BerlinTime.today().year + 50
    )
    |> validate_month_needs_year(:awarded_month, :awarded_year)
    |> validate_month_needs_year(:expires_month, :expires_year)
    |> validate_expiry_after_award()
  end

  defp validate_month_needs_year(changeset, month_field, year_field) do
    month = get_field(changeset, month_field)
    year = get_field(changeset, year_field)

    if is_nil(year) and not is_nil(month) do
      add_error(changeset, year_field, "If month is present, year must be present.")
    else
      changeset
    end
  end

  defp validate_expiry_after_award(changeset) do
    aw = {get_field(changeset, :awarded_year), get_field(changeset, :awarded_month)}
    ex = {get_field(changeset, :expires_year), get_field(changeset, :expires_month)}

    case {aw, ex} do
      {{ay, _am}, {ey, _ey}} when is_nil(ay) or is_nil(ey) ->
        changeset

      {{ay, am}, {ey, em}} ->
        if {ey, em || 12} < {ay, am || 1},
          do: add_error(changeset, :expires_year, "Expiry must not precede the award date."),
          else: changeset
    end
  end

  @doc """
  Whether a qualification has lapsed as of `today` (Berlin time). An entry with
  no expiry never expires; one that expires in month M is still valid through
  the whole of that month, and one with only an expiry year is valid through
  the whole of that year.

  The per-entry predicate for the owner's "Expired" badge; `visible_to/2` is
  the SQL equivalent that hides lapsed entries from the public. Keep the two
  in sync — they must agree on when a credential is still valid.
  """
  def expired?(qualification, today \\ BerlinTime.today())
  def expired?(%__MODULE__{expires_year: nil}, _today), do: false

  def expired?(%__MODULE__{expires_year: year, expires_month: nil}, today),
    do: today.year > year

  def expired?(%__MODULE__{expires_year: year, expires_month: month}, today),
    do: {today.year, today.month} > {year, month}

  @doc """
  Entries in display order: most recently awarded first (the way a CV reads),
  undated entries last, then alphabetically by name so the order is stable.
  """
  def ordered(query \\ __MODULE__) do
    order_by(query, [q],
      desc_nulls_last: q.awarded_year,
      desc_nulls_last: q.awarded_month,
      asc: q.name
    )
  end

  @doc """
  Scopes the query to the entries a `viewer?`-less visitor may see: an owner
  (`true`) sees every entry, everyone else sees only the non-expired ones. Kept
  in SQL so the profile card, the public section page and its agent-format
  siblings all hide the same lapsed credentials.
  """
  def visible_to(query \\ __MODULE__, owner?)
  def visible_to(query, true), do: query

  def visible_to(query, false) do
    %{year: year, month: month} = BerlinTime.today()

    # Not expired: no expiry year, or an expiry that has not yet passed. An
    # expiry with no month lasts through its whole year.
    from(q in query,
      where:
        is_nil(q.expires_year) or q.expires_year > ^year or
          (q.expires_year == ^year and
             (is_nil(q.expires_month) or q.expires_month >= ^month))
    )
  end

  # Imported and hand-entered entries alike are addressed by their UUID: unlike
  # an education slug, a credential name is neither unique nor URL-safe.
  defimpl Phoenix.Param, for: __MODULE__ do
    def to_param(%{id: id}), do: id
  end
end
