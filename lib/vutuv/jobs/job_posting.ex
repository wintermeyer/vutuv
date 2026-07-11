defmodule Vutuv.Jobs.JobPosting do
  @moduledoc """
  A job posting (issue #932). Always has one responsible human (`user`); may be
  attributed to a verified `organization` page (settable only by a role holder,
  enforced in `Vutuv.Jobs`), otherwise it carries a free-text `hiring_org_name`
  that is always rendered as unverified.

  `status` is the 90-day lifecycle: `draft` → `published` → `expired` →
  `closed`. `seo?`/`geo?` are the poster's machine-visibility toggles (same
  semantics as a member's `noindex?`/`noai?`); `visibility` (everyone/members)
  is the human audience. `country`/`remote_countries` are ISO 3166-1 alpha-2
  codes (`Vutuv.Countries`) — filter keys and JSON-LD values, not display names.

  A **draft** may be incomplete (only a title is required). **Publishing**
  additionally requires the location for the chosen workplace, an apply target
  and — for everything but a volunteer posting — a salary range (`publish_changeset/2`).
  """

  use VutuvWeb, :model

  # `gettext/1` macro so the enum labels are picked up by `mix gettext.extract`.
  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.ChangesetHelpers
  alias Vutuv.Countries
  alias Vutuv.Geo
  alias Vutuv.MarkdownContent
  alias Vutuv.Salary

  @derive {Phoenix.Param, key: :slug}

  @max_description_length 10_000

  @employment_types ~w(full_time part_time contract temporary internship apprenticeship working_student mini_job volunteer)a
  @workplace_types ~w(onsite hybrid remote)a
  @apply_kinds ~w(url email message)a
  @statuses ~w(draft published expired closed)a
  @visibilities ~w(everyone members)a
  @close_reasons ~w(filled withdrawn timeout moderation)a

  # The AGG (anti-discrimination) title hint fires when the title contains NONE
  # of these documented neutral markers — a deliberately dumb allowlist, never a
  # parser of the many gendering variants and never a detector of gendered base
  # titles ("Stewardess"), so it claims no false authority. Incomplete markers
  # like "(m/w)" or "(m)" are deliberately absent, so those titles still get the
  # hint — the case that actually matters legally.
  @neutral_markers [
    ~r<\((?:[mwdx]/){2}[mwdx]\)>i,
    ~r<\(gn\)>i,
    ~r<all genders>i,
    ~r<(?:\*|:|_|/-|/)innen>i
  ]

  schema "job_postings" do
    field(:title, :string)
    field(:hiring_org_name, :string)
    field(:description, :string)

    field(:employment_type, Ecto.Enum, values: @employment_types, default: :full_time)
    field(:workplace_type, Ecto.Enum, values: @workplace_types, default: :onsite)

    field(:street_address, :string)
    field(:zip_code, :string)
    field(:city, :string)
    field(:country, :string)
    field(:remote_countries, {:array, :string}, default: [])
    field(:lat, :float)
    field(:lon, :float)

    field(:salary_min, :integer)
    field(:salary_max, :integer)
    field(:salary_currency, :string, default: "EUR")
    field(:salary_period, :string, default: "year")

    field(:apply_kind, Ecto.Enum, values: @apply_kinds, default: :url)
    field(:apply_url, :string)
    field(:apply_email, :string)

    field(:language, :string, default: "de")
    field(:slug, :string)

    field(:seo?, :boolean, default: true)
    field(:geo?, :boolean, default: true)
    field(:visibility, Ecto.Enum, values: @visibilities, default: :everyone)

    field(:status, Ecto.Enum, values: @statuses, default: :draft)
    field(:first_published_at, :naive_datetime)
    field(:expires_on, :date)
    field(:closed_at, :naive_datetime)
    field(:close_reason, Ecto.Enum, values: @close_reasons)

    field(:view_count, :integer, default: 0)
    field(:apply_click_count, :integer, default: 0)

    field(:frozen_at, :naive_datetime)

    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:organization, Vutuv.Organizations.Organization)
    has_many(:job_posting_tags, Vutuv.Jobs.JobPostingTag, on_replace: :delete)
    has_many(:tags, through: [:job_posting_tags, :tag])
    has_many(:images, Vutuv.Jobs.JobPostingImage)

    timestamps()
  end

  def employment_types, do: @employment_types
  def workplace_types, do: @workplace_types
  def apply_kinds, do: @apply_kinds
  def statuses, do: @statuses
  def visibilities, do: @visibilities
  def max_description_length, do: @max_description_length

  @doc "Whether this is an unpaid volunteer posting (renders 'Ehrenamtlich', no salary)."
  def volunteer?(%__MODULE__{employment_type: :volunteer}), do: true
  def volunteer?(_), do: false

  @doc "Whether a report freeze (or a hidden author) hides this from the public."
  def moderation_hidden?(%__MODULE__{frozen_at: frozen_at}), do: frozen_at != nil

  # --- labels (single source, shared by editor / detail page / agent docs) ---

  def employment_type_label(:full_time), do: gettext("Full-time")
  def employment_type_label(:part_time), do: gettext("Part-time")
  def employment_type_label(:contract), do: gettext("Contract")
  def employment_type_label(:temporary), do: gettext("Temporary")
  def employment_type_label(:internship), do: gettext("Internship")
  def employment_type_label(:apprenticeship), do: gettext("Apprenticeship")
  def employment_type_label(:working_student), do: gettext("Working student")
  def employment_type_label(:mini_job), do: gettext("Mini-job")
  def employment_type_label(:volunteer), do: gettext("Volunteer")

  def employment_type_label(kind) when is_binary(kind),
    do: employment_type_label(String.to_existing_atom(kind))

  def workplace_type_label(:onsite), do: gettext("On-site")
  def workplace_type_label(:hybrid), do: gettext("Hybrid")
  def workplace_type_label(:remote), do: gettext("Remote")

  def workplace_type_label(kind) when is_binary(kind),
    do: workplace_type_label(String.to_existing_atom(kind))

  def employment_type_options, do: Enum.map(@employment_types, &{employment_type_label(&1), &1})
  def workplace_type_options, do: Enum.map(@workplace_types, &{workplace_type_label(&1), &1})

  @doc """
  The schema.org `employmentType` value(s) for the JSON-LD (an array). vutuv's
  German employment types that have no exact schema.org member map to the
  closest plus `OTHER`.
  """
  def schema_org_employment_type(:full_time), do: ["FULL_TIME"]
  def schema_org_employment_type(:part_time), do: ["PART_TIME"]
  def schema_org_employment_type(:contract), do: ["CONTRACTOR"]
  def schema_org_employment_type(:temporary), do: ["TEMPORARY"]
  def schema_org_employment_type(:internship), do: ["INTERN"]
  def schema_org_employment_type(:apprenticeship), do: ["OTHER"]
  def schema_org_employment_type(:working_student), do: ["PART_TIME", "OTHER"]
  def schema_org_employment_type(:mini_job), do: ["PART_TIME", "OTHER"]
  def schema_org_employment_type(:volunteer), do: ["VOLUNTEER"]

  def schema_org_employment_type(kind) when is_binary(kind),
    do: schema_org_employment_type(String.to_existing_atom(kind))

  @doc """
  Whether `title` should get the non-blocking AGG gender-marker hint (it lacks
  every documented neutral marker). A suggestion, never legal advice.
  """
  def agg_hint?(title) when is_binary(title),
    do: not Enum.any?(@neutral_markers, &Regex.match?(&1, title))

  def agg_hint?(_), do: true

  # --- changesets -----------------------------------------------------------

  @castable ~w(title hiring_org_name description employment_type workplace_type
               street_address zip_code city country remote_countries
               salary_min salary_max salary_currency salary_period
               apply_kind apply_url apply_email language seo? geo? visibility)a

  @doc """
  Draft-safe changeset: field validity, but only the title is required, so a
  half-finished posting saves. Location coordinates are resolved offline from
  zip + country here, and location fields irrelevant to the workplace type are
  cleared.
  """
  def changeset(job_posting, attrs) do
    job_posting
    |> cast(attrs, @castable)
    |> ChangesetHelpers.trim_fields([
      :title,
      :hiring_org_name,
      :street_address,
      :zip_code,
      :city,
      :apply_url,
      :apply_email
    ])
    |> update_change(:country, &upcase/1)
    |> normalize_remote_countries()
    |> validate_required([:title])
    |> validate_length(:title, max: 255)
    |> validate_length(:hiring_org_name, max: 255)
    |> validate_length(:description, max: @max_description_length)
    |> validate_length(:street_address, max: 255)
    |> validate_length(:zip_code, max: 32)
    |> validate_length(:city, max: 255)
    |> validate_length(:apply_url, max: 255)
    |> validate_length(:apply_email, max: 255)
    |> validate_inclusion(:salary_currency, Salary.currencies())
    |> validate_inclusion(:salary_period, Salary.periods())
    |> validate_inclusion(:language, Application.get_env(:vutuv, :locales, ~w(en de)))
    |> MarkdownContent.validate_no_images(:description)
    |> validate_salary_range()
    |> validate_country_code()
    |> validate_remote_countries()
    |> validate_apply_format()
    |> normalize_location()
    |> put_coordinates()
  end

  @doc """
  Publish changeset: everything `changeset/2` checks, plus the fields a live
  posting must have — the location for the chosen workplace, an apply target,
  and a salary range (except for a volunteer posting).
  """
  def publish_changeset(job_posting, attrs) do
    job_posting
    |> changeset(attrs)
    |> validate_location_for_publish()
    |> validate_apply_for_publish()
    |> validate_salary_for_publish()
  end

  @doc "Moves the lifecycle status; timestamps are stamped in the context."
  def status_changeset(job_posting, status) when status in @statuses do
    change(job_posting, status: status)
  end

  defp normalize_remote_countries(changeset) do
    case get_change(changeset, :remote_countries) do
      nil ->
        changeset

      codes ->
        cleaned =
          codes
          |> Enum.map(fn c -> c |> to_string() |> String.trim() |> String.upcase() end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        put_change(changeset, :remote_countries, cleaned)
    end
  end

  # Onsite/hybrid have a real office; remote has applicant countries. Clear the
  # fields that do not apply so a workplace switch never leaves stale data.
  defp normalize_location(changeset) do
    case get_field(changeset, :workplace_type) do
      :remote ->
        changeset
        |> put_change(:street_address, nil)
        |> put_change(:zip_code, nil)
        |> put_change(:city, nil)
        |> put_change(:country, nil)

      _ ->
        put_change(changeset, :remote_countries, [])
    end
  end

  # Offline zip → coordinates (Vutuv.Geo). nil when unresolvable or remote; the
  # posting still publishes.
  defp put_coordinates(changeset) do
    zip = get_field(changeset, :zip_code)
    country = get_field(changeset, :country)

    case zip && country && Geo.coordinates(country, zip) do
      {lat, lon} -> changeset |> put_change(:lat, lat) |> put_change(:lon, lon)
      _ -> changeset |> put_change(:lat, nil) |> put_change(:lon, nil)
    end
  end

  defp validate_salary_range(changeset) do
    min = get_field(changeset, :salary_min)
    max = get_field(changeset, :salary_max)

    changeset
    |> maybe_validate_number(:salary_min)
    |> maybe_validate_number(:salary_max)
    |> then(fn cs ->
      if is_integer(min) and is_integer(max) and min > max,
        do: add_error(cs, :salary_max, "must be greater than or equal to the minimum"),
        else: cs
    end)
  end

  defp maybe_validate_number(changeset, field) do
    if get_field(changeset, field),
      do: validate_number(changeset, field, greater_than: 0),
      else: changeset
  end

  defp validate_country_code(changeset) do
    validate_change(changeset, :country, fn :country, code ->
      if Countries.valid?(code), do: [], else: [country: "is not a valid country"]
    end)
  end

  defp validate_remote_countries(changeset) do
    validate_change(changeset, :remote_countries, fn :remote_countries, codes ->
      if Enum.all?(codes, &Countries.valid?/1),
        do: [],
        else: [remote_countries: "contains an invalid country"]
    end)
  end

  # Format only (presence is a publish rule): a stored apply URL is offered as an
  # outbound link, so the same literal SSRF guard the org website check uses runs here.
  # Format only (presence is a publish rule). A stored apply URL is offered as
  # an outbound link, so the shared http(s) + SSRF guard runs here too.
  defp validate_apply_format(changeset) do
    changeset
    |> ChangesetHelpers.validate_url(:apply_url)
    |> validate_apply_email()
  end

  defp validate_apply_email(changeset) do
    case get_change(changeset, :apply_email) do
      nil -> changeset
      _ -> validate_format(changeset, :apply_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    end
  end

  # Onsite/hybrid: an office someone commutes to. Remote: where applicants live.
  defp validate_location_for_publish(changeset) do
    case get_field(changeset, :workplace_type) do
      :remote ->
        if get_field(changeset, :remote_countries) == [],
          do: add_error(changeset, :remote_countries, "can't be blank"),
          else: changeset

      _ ->
        validate_required(changeset, [:zip_code, :city, :country])
    end
  end

  defp validate_apply_for_publish(changeset) do
    case get_field(changeset, :apply_kind) do
      :url -> validate_required(changeset, [:apply_url])
      :email -> validate_required(changeset, [:apply_email])
      _ -> changeset
    end
  end

  # Pay range required to publish (EU pay-transparency lead), except a volunteer
  # posting, which renders "Ehrenamtlich".
  defp validate_salary_for_publish(changeset) do
    if get_field(changeset, :employment_type) == :volunteer do
      changeset
    else
      validate_required(changeset, [:salary_min, :salary_max, :salary_currency, :salary_period])
    end
  end

  defp upcase(nil), do: nil
  defp upcase(value), do: value |> String.trim() |> String.upcase()
end
