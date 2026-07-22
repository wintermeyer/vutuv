defmodule Vutuv.Profiles.WorkExperience do
  @moduledoc false

  use VutuvWeb, :model
  import Vutuv.Organizations.Query, only: [organization_public_row: 1]
  alias Vutuv.ChangesetHelpers
  alias Vutuv.Mentions
  alias Vutuv.Profiles.CvSection
  alias Vutuv.Profiles.Qualification

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
    # The author's "tell my followers about this" choice (issue #980), taken
    # once when the entry is created — `CvSection.cast_announcement/2` ignores
    # the param on an update. Deliberately NOT in @cast_fields.
    field(:announce_to_followers?, :boolean, default: false)

    belongs_to(:user, Vutuv.Accounts.User)
    # Optional link to a verified organization page (issue #931). nil = free-text
    # only; the `organization` string column above stays authoritative for display
    # whenever there is no link. Never required, never rewrites the member's text.
    # Named `organization_page` (not `organization`) so it can't collide with the
    # free-text `organization` field; the FK column is `organization_id`.
    belongs_to(:organization_page, Vutuv.Organizations.Organization,
      foreign_key: :organization_id
    )

    # Optional link to the credential the member earned this job with (issue
    # #858): "Mit Qualifikation: Gesellenbrief Metallbauer". nil for most jobs;
    # deleting the credential clears the link (ON DELETE SET NULL) but keeps
    # the job. Only ever one of the member's own credentials — the changeset
    # rejects a foreign id.
    belongs_to(:qualification, Qualification)

    timestamps()
  end

  @cast_fields ~w(title description kind start_month start_year organization end_month end_year slug organization_id qualification_id)a

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
    |> CvSection.cast_announcement(params)
    |> validate_required([:title, :organization, :kind])
    |> validate_inclusion(:kind, @kinds)
    # Match the varchar(255) columns (and cap the text description sanely) so
    # an oversized value is a changeset error, never a raised Postgres 22001 —
    # inside the import transaction that raise 500ed the whole import.
    |> validate_length(:title, max: 255)
    |> validate_length(:organization, max: 255)
    |> validate_length(:description, max: 10_000)
    |> Mentions.validate_mentions_exist(:description)
    |> ChangesetHelpers.validate_period()
    |> validate_organization_link()
    |> validate_qualification_link()
    |> CvSection.put_slug(__MODULE__, [:title, :organization])
    # The slug derives from title + organization, so two near-cap values can
    # still overrun its own varchar(255) column.
    |> validate_length(:slug, max: 255)
    |> unique_constraint(:slug)
  end

  # Issue #931: a link is a display convenience the member opts into by accepting
  # a suggestion, so the target is only ever a **verified** (active, non-frozen)
  # organization. A organization_id that is not currently linkable — unknown, pending,
  # frozen or archived — is silently dropped back to nil rather than erroring:
  # the member never types the id (it rides in from the suggestion), so a stale
  # target should quietly fall back to the free-text organization, not block the
  # save. `foreign_key_constraint/2` still guards a genuinely dangling id.
  defp validate_organization_link(changeset) do
    changeset =
      case get_change(changeset, :organization_id) do
        nil ->
          changeset

        organization_id ->
          if linkable_organization?(organization_id),
            do: changeset,
            else: put_change(changeset, :organization_id, nil)
      end

    foreign_key_constraint(changeset, :organization_id)
  end

  defp linkable_organization?(organization_id) do
    Vutuv.Repo.exists?(
      from(c in Vutuv.Organizations.Organization,
        where: c.id == ^organization_id and organization_public_row(c)
      )
    )
  end

  # Issue #858: the cited credential must be one of the member's own — the form
  # only offers those, so a foreign id is tampering and errors instead of being
  # silently dropped (unlike the suggestion-fed organization link above). The
  # lookup is scoped to the owning user, never trusting the submitted id;
  # clearing the link (a nil change) always passes.
  defp validate_qualification_link(changeset) do
    changeset =
      case get_change(changeset, :qualification_id) do
        nil ->
          changeset

        qualification_id ->
          if own_qualification?(get_field(changeset, :user_id), qualification_id),
            do: changeset,
            else: add_error(changeset, :qualification_id, "is invalid")
      end

    foreign_key_constraint(changeset, :qualification_id)
  end

  defp own_qualification?(nil, _qualification_id), do: false

  defp own_qualification?(user_id, qualification_id) do
    Vutuv.Repo.exists?(
      from(q in Qualification, where: q.id == ^qualification_id and q.user_id == ^user_id)
    )
  end

  @doc """
  The associations every rendering of a work experience preloads: the verified
  organization page (issue #931) and the cited credential (issue #858). One
  list, so a new rendering surface (or a new ride-along association) cannot
  silently miss one — the display helpers fall through to nil on an unloaded
  association, which would quietly drop the fact instead of crashing.
  """
  def display_preloads, do: [:organization_page, :qualification]

  @doc """
  The loaded credential this job cites (issue #858), or nil — unlinked, or the
  association not preloaded. This is the one place the display policy lives:
  the citation is deliberately NOT scoped by `Qualification.visible_to/2`, so
  a lapsed credential keeps showing on the jobs it earned (its show page stays
  reachable by id) even after it drops off the public Certificates & licenses
  card. `Markdown.work_qualification_note/1` matches the same shape for the
  doc/CV note.
  """
  def cited_qualification(%{qualification: %Qualification{} = qualification}), do: qualification
  def cited_qualification(_work), do: nil

  @doc """
  Splits an already-ordered list into its CV categories: `{kind, entries}`
  pairs in `kinds/0` order (employment, internship, volunteer), empty
  categories dropped, the given (date) order kept within each. The shared
  grouping for every list rendering, so the profile card, the section page
  and the editor can never disagree on category order.
  """
  def group_by_kind(work_experiences), do: CvSection.group_by_kind(work_experiences, @kinds)

  @doc """
  Newest first, the way a CV reads: ongoing roles (no end date) lead, then by
  end date, then by start date. Delegates to the shared `CvSection.order_by_date/1`.
  """
  def order_by_date(query), do: CvSection.order_by_date(query)

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
